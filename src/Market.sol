// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarginVault} from "./interfaces/IMarginVault.sol";
import {IMarketCore} from "./interfaces/IMarketCore.sol";
import {IPriceSource} from "./interfaces/IPriceSource.sol";
import {CurveMath as Curve} from "./libraries/CurveMath.sol";
import {FeeMath as Fees} from "./libraries/FeeMath.sol";
import {FixedPointMath as F} from "./libraries/FixedPointMath.sol";
import {FundingMath as Funding} from "./libraries/FundingMath.sol";
import {MarkTwap} from "./libraries/MarkTwap.sol";
import {RiskMath as Risk} from "./libraries/RiskMath.sol";
import {PripoTypes as T} from "./types/PripoTypes.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Immutable clone runtime for isolated, capped virtual-curve trading.
/// @dev Liquidation, backstop, ADL and resolver settlement are separate implementation milestones.
contract Market is IMarketCore, Initializable, ReentrancyGuard {
    using MarkTwap for MarkTwap.State;

    uint256 public constant USER_NOTIONAL_CAP = 2_000e18;
    uint256 public constant MARKET_NOTIONAL_CAP = 25_000e18;
    IMarginVault public vault;
    bytes32 public feedId;
    bool public externalIndex;
    bool public guardianPaused;
    T.MarketConfig private _config;
    T.AmmState private _amm;
    T.FundingState private _funding;
    uint256 public longSize;
    uint256 public shortSize;
    mapping(address => T.Position) private _positions;
    MarkTwap.State private _twap;
    uint256 private _index;
    uint64 private _indexBlock;

    struct OpenQuote {
        T.Fill fill;
        uint256 fee;
        uint256 margin;
        int256 newSize;
        uint256 newEntry;
    }

    struct CloseQuote {
        T.Fill fill;
        uint256 fee;
        int256 pnl;
        int256 closedSize;
        uint256 closedEntry;
    }

    struct Observation {
        uint256 price;
        uint64 updatedBlock;
        uint16 confidence;
        bool isExternal;
    }

    constructor() {
        _disableInitializers();
    }

    /// @notice The registrar must register, fund and initialize the clone atomically.
    // Registrar authorization, initializer and nonReentrant guard cover the oracle callback during bootstrap.
    // slither-disable-next-line reentrancy-benign
    function initialize(
        IMarginVault vault_,
        bytes32 feedId_,
        bool externalIndex_,
        T.MarketConfig calldata cfg,
        uint256 initialPrice,
        uint256 depth
    ) external nonReentrant initializer {
        if (address(vault_).code.length == 0 || vault_.registrarOf(address(this)) != msg.sender) revert Unauthorized();
        if (cfg.creator != vault_.creatorOf(address(this))) revert InvalidConfiguration();
        vault = vault_;
        feedId = feedId_;
        externalIndex = externalIndex_;
        _validateConfig(cfg);
        _config = cfg;
        _config.status = T.Status.Active;
        _config.statusSince = _block();
        if (externalIndex) {
            _refreshPrice("", 0);
            initialPrice = _index;
        }
        _amm = Curve.seed(initialPrice, depth);
        _validateDepth(depth);
        _funding.lastBlock = _block();
        _twap.initialize(Curve.mark(_amm), _block());
    }

    function open(int256 size, uint256 limitPrice, bytes calldata update) external payable nonReentrant {
        _open(msg.sender, size, limitPrice, update, new bytes32[](0));
    }

    function openFor(address user, int256 size, uint256 limitPrice, bytes calldata update)
        external
        payable
        nonReentrant
    {
        _open(user, size, limitPrice, update, new bytes32[](0));
    }

    function openFor(address user, int256 size, uint256 limitPrice, bytes calldata update, bytes32[] calldata proof)
        external
        payable
        nonReentrant
    {
        _open(user, size, limitPrice, update, proof);
    }

    // Every caller holds nonReentrant. The oracle observes pre-trade state; vault ledger methods make no callbacks.
    // slither-disable-next-line reentrancy-eth
    function _open(address user, int256 size, uint256 limitPrice, bytes memory update, bytes32[] memory proof) private {
        // Enum discrimination, not a timestamp or cash-balance equality.
        // slither-disable-next-line incorrect-equality
        bool wasActive = _config.status == T.Status.Active;
        _touch();
        if (!wasActive || guardianPaused) revert MarketNotActive();
        _refreshPrice(update, msg.value);
        // A fresh observation prevents a transition caused solely by an expired cache.
        // slither-disable-next-line incorrect-equality
        if (_config.status == T.Status.Degraded) _setStatus(T.Status.Active);
        _settleFunding(user);
        OpenQuote memory q = _quoteOpen(user, size);
        _checkLimit(size, q.fill.avgPrice, limitPrice);
        vault.checkAndConsume(user, msg.sender, q.fill.quoteAmount, false, proof);
        vault.lock(user, q.margin);
        _chargeFee(user, q.fee, false);
        T.Position storage p = _positions[user];
        int256 oldSize = p.size;
        _resize(oldSize, q.newSize);
        p.size = q.newSize;
        p.entryCost = q.newEntry;
        p.lastFundingIndex = size > 0 ? _funding.longIndex : _funding.shortIndex;
        _amm.entryCostNet += size > 0 ? F.toInt(q.fill.quoteAmount) : -F.toInt(q.fill.quoteAmount);
        _applyFill(q.fill);
        emit PositionOpened(address(this), user, msg.sender, size, q.fill.avgPrice, q.margin, q.fee);
    }

    /// @dev The update argument is retained for ABI compatibility. Closes never call an oracle and reject native value.
    function close(uint256 fraction, uint256 limitPrice, bytes calldata) external payable nonReentrant {
        _close(msg.sender, fraction, limitPrice, new bytes32[](0));
    }

    function closeFor(address user, uint256 fraction, uint256 limitPrice, bytes calldata)
        external
        payable
        nonReentrant
    {
        _close(user, fraction, limitPrice, new bytes32[](0));
    }

    function closeFor(address user, uint256 fraction, uint256 limitPrice, bytes calldata, bytes32[] calldata proof)
        external
        payable
        nonReentrant
    {
        _close(user, fraction, limitPrice, proof);
    }

    // All callers hold nonReentrant; the pinned vault's settlement methods perform no token transfers or callbacks.
    // slither-disable-next-line reentrancy-no-eth
    function _close(address user, uint256 fraction, uint256 limitPrice, bytes32[] memory proof) private {
        if (msg.value != 0) revert UnexpectedValue();
        _touch();
        int256 fundingOwed = _settleFunding(user);
        CloseQuote memory q = _quoteClose(user, fraction);
        _checkLimit(-q.closedSize, q.fill.avgPrice, limitPrice);
        vault.checkAndConsume(user, msg.sender, q.fill.quoteAmount, true, proof);
        T.Position storage p = _positions[user];
        int256 remaining = p.size - q.closedSize;
        _resize(p.size, remaining);
        p.size = remaining;
        p.entryCost -= q.closedEntry;
        _amm.entryCostNet -= q.closedSize > 0 ? F.toInt(q.closedEntry) : -F.toInt(q.closedEntry);
        _applyFill(q.fill);
        vault.settlePnl(user, q.pnl);
        _chargeFee(user, q.fee, true);
        // Exact position-size arithmetic must detect the final close to clear its snapshot and residual entry cost.
        // slither-disable-next-line incorrect-equality
        if (remaining == 0) {
            uint256 debt = vault.coverDebt(user);
            if (debt != 0) emit BadDebt(address(this), user, debt, 0);
            vault.release(user, F.toUint(vault.locked(user, address(this))));
            delete _positions[user];
        }
        // Partial closes retain collateral. The owner can remove the excess subject to the initial-margin checks.
        emit PositionClosed(address(this), user, msg.sender, q.closedSize, q.fill.avgPrice, q.pnl, fundingOwed, q.fee);
    }

    function addMargin(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (_positions[msg.sender].size == 0) revert NoPosition();
        _touch();
        _settleFunding(msg.sender);
        vault.lock(msg.sender, amount);
        emit MarginChanged(address(this), msg.sender, F.toInt(amount));
    }

    function removeMargin(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        T.Position memory p = _positions[msg.sender];
        if (p.size == 0) revert NoPosition();
        _touch();
        _settleFunding(msg.sender);
        uint256 required = _initialMargin(p.size, p.entryCost);
        int256 remaining = vault.locked(msg.sender, address(this)) - F.toInt(amount);
        if (remaining < F.toInt(required)) {
            revert InsufficientMargin(remaining > 0 ? F.toUint(remaining) : 0, required);
        }
        int256 equity = remaining + _referencePnl(p);
        uint256 minimum = Math.ceilDiv(p.entryCost, _config.maxLeverageX);
        if (equity < F.toInt(minimum)) revert InsufficientMargin(equity > 0 ? F.toUint(equity) : 0, minimum);
        vault.release(msg.sender, amount);
        emit MarginChanged(address(this), msg.sender, -F.toInt(amount));
    }

    // Guarded adapter reads happen after an internally consistent funding/TWAP checkpoint.
    // slither-disable-next-line reentrancy-eth
    function poke() external nonReentrant {
        _touch();
        if (externalIndex) {
            Observation memory o = _readSource(_config.priceSource, "", 0);
            if (!_fresh(o) && _config.secondarySource != address(0)) o = _readSource(_config.secondarySource, "", 0);
            if (_fresh(o)) {
                _index = o.price;
                _indexBlock = o.updatedBlock;
                if (!guardianPaused) _setStatus(T.Status.Active);
            }
        }
    }

    function sweepFundingSurplus() external nonReentrant {
        _touch();
        uint256 amount;
        // The vault applies the returned transfer amount to its authoritative pool; the duplicate newPool is unused.
        // slither-disable-next-line unused-return
        (_funding,, amount) = Funding.sweep(_funding, vault.ledger(address(this)).fundingPool, longSize, shortSize);
        vault.sweepFunding(amount);
        emit FundingSurplusSwept(address(this), amount);
    }

    function quoteOpen(int256 size) external view returns (uint256, uint256, uint256, uint256) {
        return quoteOpenFor(msg.sender, size);
    }

    /// @notice Margin returned is the additional free collateral needed, including any settled funding debt.
    function quoteOpenFor(address user, int256 size) public view returns (uint256, uint256, uint256, uint256) {
        OpenQuote memory q = _quoteOpen(user, size);
        return (q.fill.avgPrice, q.fee, q.margin, q.fill.newMark);
    }

    function _quoteOpen(address user, int256 size) private view returns (OpenQuote memory q) {
        if (user == address(0) || size == 0 || size == type(int256).min) revert InvalidSize();
        T.Position memory p = _positions[user];
        if (p.size != 0 && (p.size > 0) != (size > 0)) revert PositionExists();
        q.fill = Curve.quote(_amm, size);
        q.newSize = p.size + size;
        q.newEntry = p.entryCost + q.fill.quoteAmount;
        uint256 newLongs = longSize + (size > 0 ? F.abs(size) : 0);
        uint256 newShorts = shortSize + (size < 0 ? F.abs(size) : 0);
        uint256 baseCap = Risk.sideCap(_amm.baseAtSeed, _config.sideCapBps);
        if (newLongs > baseCap || newShorts > baseCap) revert OICapExceeded(baseCap, Math.max(newLongs, newShorts));
        uint256 notional = Math.mulDiv(Math.max(newLongs, newShorts), q.fill.newMark, F.WAD, Math.Rounding.Ceil);
        uint256 cap = _oiCap();
        if (notional > cap) revert OICapExceeded(cap, notional);
        uint256 userNotional = Math.mulDiv(F.abs(q.newSize), q.fill.newMark, F.WAD, Math.Rounding.Ceil);
        if (userNotional > USER_NOTIONAL_CAP) revert OICapExceeded(USER_NOTIONAL_CAP, userNotional);
        uint256 required = _initialMargin(q.newSize, q.newEntry);
        int256 available = vault.locked(user, address(this)) - _fundingOwed(p);
        q.margin = available < F.toInt(required) ? F.toUint(F.toInt(required) - available) : 0;
        uint256 skewBefore = _absoluteSkew(longSize, shortSize);
        bool reducesSkew = _absoluteSkew(newLongs, newShorts) < skewBefore;
        q.fee = Fees.takerFee(q.fill.quoteAmount, _config.takerFeeBps, skewBefore, reducesSkew);
    }

    function quoteClose(address user, uint256 fraction) external view returns (uint256, uint256, int256, int256) {
        CloseQuote memory q = _quoteClose(user, fraction);
        return (q.fill.avgPrice, q.fee, q.pnl, _fundingOwed(_positions[user]));
    }

    function _quoteClose(address user, uint256 fraction) private view returns (CloseQuote memory q) {
        T.Position memory p = _positions[user];
        // Zero is the exact empty-position sentinel.
        // slither-disable-next-line incorrect-equality
        if (p.size == 0) revert NoPosition();
        if (fraction == 0 || fraction > F.WAD) revert InvalidSize();
        uint256 amount = Math.mulDiv(F.abs(p.size), fraction, F.WAD);
        q.closedEntry = Curve.closedEntryCost(p.entryCost, amount, F.abs(p.size));
        q.closedSize = p.size > 0 ? F.toInt(amount) : -F.toInt(amount);
        q.fill = Curve.quoteExit(_amm, q.closedSize);
        q.pnl = p.size > 0
            ? F.toInt(q.fill.quoteAmount) - F.toInt(q.closedEntry)
            : F.toInt(q.closedEntry) - F.toInt(q.fill.quoteAmount);
        q.fee = Fees.takerFee(q.fill.quoteAmount, _config.takerFeeBps, 0, false);
    }

    function health(address user) external view returns (int256 healthWad, bool liquidatable) {
        T.Position memory p = _positions[user];
        // Zero is the exact empty-position sentinel.
        // slither-disable-next-line incorrect-equality
        if (p.size == 0) return (type(int256).max, false);
        int256 equity = vault.locked(user, address(this)) + _referencePnl(p) - _fundingOwed(p);
        uint256 magnitude = Math.mulDiv(F.abs(equity), F.WAD, p.entryCost);
        healthWad = equity < 0 ? -F.toInt(magnitude) : F.toInt(magnitude);
        uint256 mmr = _isDegraded() ? 1500 : _config.mmrBps;
        liquidatable = equity < F.toInt(Math.mulDiv(p.entryCost, mmr, F.BPS, Math.Rounding.Ceil));
    }

    function realizablePnl(address user) external view returns (int256, int256) {
        T.Position memory p = _positions[user];
        // Zero is the exact empty-position sentinel.
        // slither-disable-next-line incorrect-equality
        if (p.size == 0) return (0, 0);
        return
            (Curve.realizablePnl(_amm, p.size, p.entryCost), Curve.realizablePnl(_twapReserves(), p.size, p.entryCost));
    }

    function _referencePnl(T.Position memory p) private view returns (int256 pnl) {
        pnl = Curve.realizablePnl(_twapReserves(), p.size, p.entryCost);
        if (externalIndex && !_isDegraded()) {
            uint256 quote =
                Math.mulDiv(F.abs(p.size), _index, F.WAD, p.size > 0 ? Math.Rounding.Floor : Math.Rounding.Ceil);
            int256 indexPnl = p.size > 0 ? F.toInt(quote) - F.toInt(p.entryCost) : F.toInt(p.entryCost) - F.toInt(quote);
            if (indexPnl < pnl) pnl = indexPnl;
        }
    }

    function _twapReserves() private view returns (T.AmmState memory a) {
        a = _amm;
        uint256 twap = twapPrice();
        a.baseReserve = Math.sqrt(Math.mulDiv(a.k, F.WAD, twap));
        a.quoteReserve = Math.ceilDiv(a.k, a.baseReserve);
    }

    function twapPrice() public view returns (uint256) {
        return _twap.consult(_isDegraded() ? 600 : 300, _block());
    }

    function ammState() external view returns (T.AmmState memory) {
        return _amm;
    }

    function fundingState() external view returns (T.FundingState memory) {
        return _previewFunding();
    }

    function position(address user) external view returns (T.Position memory p) {
        p = _positions[user];
        int256 collateral = vault.locked(user, address(this));
        p.margin = collateral > 0 ? F.toUint(collateral) : 0;
    }

    function positionDebt(address user) external view returns (uint256) {
        int256 collateral = vault.locked(user, address(this));
        return collateral < 0 ? F.abs(collateral) : 0;
    }

    function curveAccounts() external view returns (uint256, int256, int256) {
        return (_amm.curveBase, _amm.entryCostNet, vault.ledger(address(this)).clearing);
    }

    function markPrice() external view returns (uint256) {
        return Curve.mark(_amm);
    }

    function indexPrice() external view returns (uint256, uint64, bool) {
        return (_index, _indexBlock, externalIndex);
    }

    function config() external view returns (T.MarketConfig memory) {
        return _config;
    }

    function status() external view returns (uint8, uint64) {
        return (uint8(_config.status), _config.statusSince);
    }

    function openInterest() external view returns (uint256, uint256, uint256) {
        uint256 mark = Curve.mark(_amm);
        return (Math.mulDiv(longSize, mark, F.WAD), Math.mulDiv(shortSize, mark, F.WAD), _oiCap());
    }

    function fundingRatePerBlock() public view returns (int256) {
        if (_isDegraded()) return 0;
        return _cachedRate();
    }

    function _cachedRate() private view returns (int256) {
        return externalIndex
            ? Funding.oracleRate(Curve.mark(_amm), _index, 12_000, _config.fundingCapPerBlock)
            : Funding.skewRate(longSize, shortSize, 0.05e18, 12_000, _config.fundingCapPerBlock);
    }

    function _previewFunding() private view returns (T.FundingState memory f) {
        f = _funding;
        uint64 current = _block();
        uint64 end = current;
        if (externalIndex) {
            uint64 cutoff = SafeCast.toUint64(uint256(_indexBlock) + _config.degradeAfterBlocks + 1);
            if (end > cutoff) end = cutoff;
        }
        if (end > f.lastBlock && _config.status != T.Status.Degraded) {
            uint256 referencePrice = externalIndex ? _index : _twap.consult(300, current);
            f = Funding.accrue(f, longSize, shortSize, _cachedRate(), referencePrice, end, _config.receiveCapX);
        }
        f.lastBlock = current;
    }

    function _touch() private {
        int256 rate = fundingRatePerBlock();
        _funding = _previewFunding();
        // The equality discriminates an enum; oracle age uses an ordered comparison.
        // slither-disable-next-line incorrect-equality
        if (_isDegraded() && _config.status == T.Status.Active) _setStatus(T.Status.Degraded);
        _twap.write(Curve.mark(_amm), _block());
        emit FundingAccrued(address(this), rate, _funding.longIndex, _funding.shortIndex, _block());
    }

    function _settleFunding(address user) private returns (int256 owed) {
        T.Position storage p = _positions[user];
        // Zero is the exact empty-position sentinel.
        // slither-disable-next-line incorrect-equality
        if (p.size == 0) return 0;
        (_funding, owed, p.lastFundingIndex) = Funding.settle(_funding, p.size, p.lastFundingIndex);
        vault.settleFunding(user, owed);
    }

    function _fundingOwed(T.Position memory p) private view returns (int256 owed) {
        // Zero is the exact empty-position sentinel.
        // slither-disable-next-line incorrect-equality
        if (p.size == 0) return 0;
        // Read-only simulation needs only the debit; it deliberately discards the simulated state and snapshot.
        // slither-disable-next-line unused-return
        (, owed,) = Funding.settle(_previewFunding(), p.size, p.lastFundingIndex);
    }

    function _resize(int256 oldSize, int256 newSize) private {
        _funding = Funding.changeSize(_funding, oldSize, newSize);
        if (oldSize > 0) longSize -= F.abs(oldSize);
        if (oldSize < 0) shortSize -= F.abs(oldSize);
        if (newSize > 0) longSize += F.abs(newSize);
        if (newSize < 0) shortSize += F.abs(newSize);
    }

    function _applyFill(T.Fill memory fill) private {
        _amm.baseReserve = fill.baseReserve;
        _amm.quoteReserve = fill.quoteReserve;
        _twap.write(fill.newMark, _block());
    }

    function _chargeFee(address user, uint256 fee, bool fromLocked) private {
        T.FeeBreakdown memory split = Fees.split(
            fee,
            _config.creatorShareBps,
            _config.insuranceShareBps,
            _config.referralShareBps,
            vault.referrerOf(user) != address(0)
        );
        vault.chargeFee(user, split, fromLocked);
        emit FeesAccrued(address(this), split.protocol, split.creator, split.insurance);
    }

    function remark() external nonReentrant {
        _remark("", 0);
    }

    function remark(bytes calldata update) external payable nonReentrant {
        _remark(update, msg.value);
    }

    // Only reachable from the two nonReentrant remark entry points.
    // slither-disable-next-line reentrancy-eth
    function _remark(bytes memory update, uint256 value) private {
        _touch();
        _refreshPrice(update, value);
        if (!guardianPaused) _setStatus(T.Status.Active);
    }

    // All callers hold nonReentrant, including initialization. Cache writes follow successful adapter validation.
    // slither-disable-next-line reentrancy-benign
    function _refreshPrice(bytes memory update, uint256 value) private {
        if (!externalIndex) {
            if (value != 0) revert UnexpectedValue();
            return;
        }
        Observation memory o = _readSource(_config.priceSource, update, value);
        if (!_fresh(o) && _config.secondarySource != address(0)) o = _readSource(_config.secondarySource, "", 0);
        // Reject zero price explicitly; freshness uses inequalities.
        // slither-disable-next-line incorrect-equality
        if (o.price == 0 || o.price > 1e28 || !o.isExternal || o.updatedBlock > block.number) revert InvalidOracle();
        if (o.confidence > 100) revert OracleConfidence(o.confidence);
        if (!_fresh(o)) revert StaleOracle(_block() - o.updatedBlock);
        _index = o.price;
        _indexBlock = o.updatedBlock;
    }

    function _readSource(address source, bytes memory update, uint256 value) private returns (Observation memory o) {
        try IPriceSource(source).getPrice{value: value}(feedId, update) returns (
            uint256 p, uint64 b, uint16 c, bool ext
        ) {
            o = Observation(p, b, c, ext);
        } catch {
            if (value != 0) revert InvalidOracle();
        }
    }

    function _fresh(Observation memory o) private view returns (bool) {
        return o.price != 0 && o.price <= 1e28 && o.isExternal && o.confidence <= 100 && o.updatedBlock <= block.number
            && block.number - o.updatedBlock <= _config.maxOracleAgeBlocks;
    }

    function _isDegraded() private view returns (bool) {
        // Exact enum match plus an ordered age check.
        // slither-disable-next-line incorrect-equality
        return _config.status == T.Status.Degraded
            || (externalIndex && block.number > uint256(_indexBlock) + _config.degradeAfterBlocks);
    }

    function pauseOpens() external nonReentrant {
        if (msg.sender != vault.guardian()) revert Unauthorized();
        _touch();
        guardianPaused = true;
        _setStatus(T.Status.Paused);
    }

    function resumeOpens() external nonReentrant {
        if (msg.sender != vault.governor()) revert Unauthorized();
        _touch();
        guardianPaused = false;
        _setStatus(_isDegraded() ? T.Status.Degraded : T.Status.Active);
    }

    function _setStatus(T.Status next) private {
        // Avoid duplicate enum transition events.
        // slither-disable-next-line incorrect-equality
        if (next == _config.status) return;
        emit StatusChanged(address(this), uint8(_config.status), uint8(next), _block());
        _config.status = next;
        _config.statusSince = _block();
    }

    function claimCreatorFees() external nonReentrant {
        if (msg.sender != _config.creator) revert Unauthorized();
        uint256 amount = vault.claimCreatorFees();
        emit CreatorFeesClaimed(address(this), msg.sender, amount);
    }

    function transferCreator(address to) external nonReentrant {
        if (msg.sender != _config.creator) revert Unauthorized();
        if (to == address(0)) revert InvalidAddress();
        _config.creator = to;
        vault.transferCreator(to);
        emit CreatorTransferred(msg.sender, to);
    }

    function reseed(uint256 depth) external nonReentrant {
        if (msg.sender != _config.creator) revert Unauthorized();
        if (longSize != 0 || shortSize != 0) revert PositionExists();
        if (Curve.clearing(_amm) != 0 || vault.ledger(address(this)).clearing != 0) revert AccountingInvariant();
        _touch();
        _amm = Curve.seed(Curve.mark(_amm), depth);
        _validateDepth(depth);
        _twap.write(Curve.mark(_amm), _block());
    }

    function _initialMargin(int256 size, uint256 entry) private view returns (uint256) {
        return Risk.initialMargin(_amm, size, entry, _config.maxLeverageX, _config.mmrBps, _config.sideCapBps);
    }

    function _oiCap() private view returns (uint256) {
        return Math.min(vault.ledger(address(this)).insurance * (externalIndex ? 20 : 10), MARKET_NOTIONAL_CAP);
    }

    function _validateDepth(uint256 depth) private view {
        uint256 insurance = vault.ledger(address(this)).insurance;
        if (insurance < (externalIndex ? 5_000e18 : 2_000e18)) {
            revert InsufficientInsurance(insurance, externalIndex ? 5_000e18 : 2_000e18);
        }
        uint16 multiplier = externalIndex ? 20 : 10;
        uint256 minimum = Risk.minimumDepth(insurance, multiplier, _config.sideCapBps);
        if (depth < minimum || depth > 1e28 || _amm.baseAtSeed > 1e28) revert InvalidReserves();
        uint256 coverage = Math.mulDiv(Risk.sideCap(_amm.baseAtSeed, _config.sideCapBps), Curve.mark(_amm), F.WAD);
        if (coverage < insurance * multiplier) revert InvalidReserves();
    }

    function _validateConfig(T.MarketConfig calldata c) private view {
        uint16 maximum = externalIndex ? 5 : 2;
        if (
            c.creator == address(0) || c.maxLeverageX < 2 || c.maxLeverageX > maximum || c.sideCapBps == 0
                || c.sideCapBps > Risk.sideCapBps(c.maxLeverageX) || c.mmrBps != (externalIndex ? 250 : 1500)
                || c.impactMarginBps != F.BPS || c.skewCoeff != 0 || c.takerFeeBps != 8 || c.creatorShareBps != 3000
                || c.insuranceShareBps != 3000 || c.referralShareBps != 1000 || c.receiveCapX != 10
                || c.maxOracleAgeBlocks == 0 || c.degradeAfterBlocks <= c.maxOracleAgeBlocks
                || c.degradedTwapBlocks != 600
                || c.fundingCapPerBlock > (externalIndex ? uint256(0.001e18) / 12_000 : uint256(0.005e18) / 12_000)
                || (externalIndex && c.priceSource.code.length == 0)
                || (c.secondarySource != address(0) && c.secondarySource.code.length == 0)
        ) revert InvalidConfiguration();
    }

    function _checkLimit(int256 size, uint256 average, uint256 limit) private pure {
        if ((size > 0 && average > limit) || (size < 0 && average < limit)) revert Slippage(limit, average);
    }

    function _absoluteSkew(uint256 longs, uint256 shorts) private pure returns (uint256) {
        // Exact integer-zero guard prevents division by zero.
        // slither-disable-next-line incorrect-equality
        if (longs + shorts == 0) return 0;
        return Math.mulDiv(longs > shorts ? longs - shorts : shorts - longs, F.WAD, longs + shorts);
    }

    function _block() private view returns (uint64) {
        return SafeCast.toUint64(block.number);
    }
}
