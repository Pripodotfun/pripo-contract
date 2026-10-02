// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarginVault} from "./interfaces/IMarginVault.sol";
import {IMarketCore} from "./interfaces/IMarketCore.sol";
import {CurveMath as Curve} from "./libraries/CurveMath.sol";
import {FixedPointMath as F} from "./libraries/FixedPointMath.sol";
import {FundingMath as Funding} from "./libraries/FundingMath.sol";
import {MarkTwap} from "./libraries/MarkTwap.sol";
import {PripoTypes as T} from "./types/PripoTypes.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {MarketAccounting as Engine} from "./market/MarketAccounting.sol";
import {MarketAdl as Adl} from "./market/MarketAdl.sol";
import {MarketLens as Lens} from "./market/MarketLens.sol";
import {MarketLiquidation as Liquidation} from "./market/MarketLiquidation.sol";
import {MarketMargin as Margin} from "./market/MarketMargin.sol";
import {MarketSettlement as Settlement} from "./market/MarketSettlement.sol";
import {MarketState as S} from "./market/MarketState.sol";
import {MarketTrading as Trading} from "./market/MarketTrading.sol";
import {PositionBook as Book} from "./market/PositionBook.sol";

/// @notice Immutable clone entry points with shared, fixed linked modules.
contract Market is IMarketCore, Initializable, ReentrancyGuard {
    using MarkTwap for MarkTwap.State;
    uint256 public constant USER_NOTIONAL_CAP = 2_000e18;
    uint256 public constant MARKET_NOTIONAL_CAP = 25_000e18;
    uint256 public constant MAX_POSITIONS = Book.MAX_POSITIONS;

    constructor() {
        _disableInitializers();
    }

    function vault() external view returns (IMarginVault) {
        return S.load().vault;
    }

    function feedId() external view returns (bytes32) {
        return S.load().feedId;
    }

    function externalIndex() external view returns (bool) {
        return S.load().externalIndex;
    }

    function guardianPaused() external view returns (bool) {
        return S.load().guardianPaused;
    }

    function longSize() external view returns (uint256) {
        return S.load().longSize;
    }

    function shortSize() external view returns (uint256) {
        return S.load().shortSize;
    }

    function positionCount() external view returns (uint256) {
        return S.load()._positionCount;
    }

    /// @notice Read stable slots, including zero-address holes. Pin the block across multiple pages.
    function positionAccounts(uint256 offset, uint256 limit) external view returns (address[] memory) {
        return Book.page(S.load(), offset, limit);
    }

    function settlementQuote() external view returns (T.SettlementQuote memory) {
        return Settlement.quote(S.load());
    }

    function settlementInfo() external view returns (uint256 price, uint256 haircut, uint256 profits) {
        S.Data storage s = S.load();
        return (s.settlementPrice, s.settlementHaircut, s.settlementProfits);
    }

    function health(address user) external view returns (int256, bool) {
        // Both tuple components are forwarded directly to the caller.
        // slither-disable-next-line unused-return
        return Lens.health(S.load(), user);
    }

    function realizablePnl(address user) external view returns (int256, int256) {
        // Both tuple components are forwarded directly to the caller.
        // slither-disable-next-line unused-return
        return Lens.realizablePnl(S.load(), user);
    }

    function twapPrice() public view returns (uint256) {
        return Engine.twapPrice(S.load());
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
        S.Data storage s = S.load();
        if (address(vault_).code.length == 0 || vault_.registrarOf(address(this)) != msg.sender) revert Unauthorized();
        if (cfg.creator != vault_.creatorOf(address(this))) revert InvalidConfiguration();
        s.vault = vault_;
        s.feedId = feedId_;
        s.externalIndex = externalIndex_;
        Engine.validateConfig(s, cfg);
        s._config = cfg;
        s._config.status = T.Status.Active;
        s._config.statusSince = Engine.currentBlock();
        if (s.externalIndex) {
            Engine.refreshPrice(s, "", 0);
            initialPrice = s._index;
        }
        s._amm = Curve.seed(initialPrice, depth);
        Engine.validateDepth(s, depth);
        s._funding.lastBlock = Engine.currentBlock();
        s._twap.initialize(Curve.mark(s._amm), Engine.currentBlock());
        s.vault.admitMarket(MARKET_NOTIONAL_CAP, cfg.fundingCapPerBlock);
    }

    function open(int256 size, uint256 limitPrice, bytes calldata update) external payable nonReentrant {
        Trading.open(S.load(), msg.sender, size, limitPrice, update, new bytes32[](0), msg.value);
    }

    function openFor(address user, int256 size, uint256 limitPrice, bytes calldata update)
        external
        payable
        nonReentrant
    {
        Trading.open(S.load(), user, size, limitPrice, update, new bytes32[](0), msg.value);
    }

    function openFor(address user, int256 size, uint256 limitPrice, bytes calldata update, bytes32[] calldata proof)
        external
        payable
        nonReentrant
    {
        Trading.open(S.load(), user, size, limitPrice, update, proof, msg.value);
    }

    /// @dev The update argument is retained for ABI compatibility. Closes never call an oracle and reject native value.
    function close(uint256 fraction, uint256 limitPrice, bytes calldata) external payable nonReentrant {
        if (msg.value != 0) revert UnexpectedValue();
        Trading.close(S.load(), msg.sender, fraction, limitPrice, new bytes32[](0));
    }

    function closeFor(address user, uint256 fraction, uint256 limitPrice, bytes calldata)
        external
        payable
        nonReentrant
    {
        if (msg.value != 0) revert UnexpectedValue();
        Trading.close(S.load(), user, fraction, limitPrice, new bytes32[](0));
    }

    function closeFor(address user, uint256 fraction, uint256 limitPrice, bytes calldata, bytes32[] calldata proof)
        external
        payable
        nonReentrant
    {
        if (msg.value != 0) revert UnexpectedValue();
        Trading.close(S.load(), user, fraction, limitPrice, proof);
    }

    function liquidate(address user, bytes calldata update) external payable nonReentrant {
        Liquidation.liquidate(S.load(), user, update, msg.value, new address[](0), true);
    }

    function liquidate(address user, bytes calldata update, address[] calldata candidates)
        external
        payable
        nonReentrant
    {
        Liquidation.liquidate(S.load(), user, update, msg.value, candidates, false);
    }

    function addMargin(uint256 amount) external nonReentrant {
        Margin.addMargin(S.load(), amount);
    }

    function removeMargin(uint256 amount) external nonReentrant {
        Margin.removeMargin(S.load(), amount);
    }

    function continueAdl(address user, address[] calldata candidates) external nonReentrant {
        Adl.continuePending(S.load(), user, candidates);
    }

    function completeAdl(address user, uint256 maxIterations) external nonReentrant {
        Adl.complete(S.load(), user, maxIterations);
    }

    function pendingAdl(address user) external view returns (T.AdlPending memory) {
        return S.load()._pendingAdl[user];
    }

    function pendingAdlCount() external view returns (uint256) {
        return S.load().pendingAdlCount;
    }

    function adlEligibleSize(address user) external view returns (uint256) {
        return Adl.eligibleSize(S.load(), user);
    }

    // Guarded adapter reads happen after an internally consistent funding/TWAP checkpoint.
    // slither-disable-next-line reentrancy-eth
    function poke() external nonReentrant {
        S.Data storage s = S.load();
        Engine.touch(s);
        if (s.externalIndex) {
            S.Observation memory o = Engine.readSource(s, s._config.priceSource, "", 0);
            if (!Engine.fresh(s, o) && s._config.secondarySource != address(0)) {
                o = Engine.readSource(s, s._config.secondarySource, "", 0);
            }
            if (Engine.fresh(s, o)) {
                s._index = o.price;
                s._indexBlock = o.updatedBlock;
                if (!s.guardianPaused && s.pendingAdlCount == 0) Engine.setStatus(s, T.Status.Active);
            }
        }
    }

    function sweepFundingSurplus() external nonReentrant {
        S.Data storage s = S.load();
        Engine.touch(s);
        uint256 amount;
        // The vault applies the returned transfer amount to its authoritative pool; the duplicate newPool is unused.
        // slither-disable-next-line unused-return
        (s._funding,, amount) =
            Funding.sweep(s._funding, s.vault.ledger(address(this)).fundingPool, s.longSize, s.shortSize);
        s.vault.sweepFunding(amount);
        emit FundingSurplusSwept(address(this), amount);
    }

    function quoteOpen(int256 size) external view returns (uint256, uint256, uint256, uint256) {
        return quoteOpenFor(msg.sender, size);
    }

    /// @notice Margin returned is the additional free collateral needed, including any settled funding debt.
    function quoteOpenFor(address user, int256 size) public view returns (uint256, uint256, uint256, uint256) {
        S.Data storage s = S.load();
        S.OpenQuote memory q = Lens.quoteOpen(s, user, size);
        return (q.fill.avgPrice, q.fee, q.margin, q.fill.newMark);
    }

    function quoteClose(address user, uint256 fraction) external view returns (uint256, uint256, int256, int256) {
        S.Data storage s = S.load();
        S.CloseQuote memory q = Lens.quoteClose(s, user, fraction);
        return (q.fill.avgPrice, q.fee, q.pnl, Engine.fundingOwed(s, s._positions[user]));
    }

    function ammState() external view returns (T.AmmState memory) {
        S.Data storage s = S.load();
        return s._amm;
    }

    function fundingState() external view returns (T.FundingState memory) {
        S.Data storage s = S.load();
        return Engine.previewFunding(s);
    }

    function position(address user) external view returns (T.Position memory p) {
        S.Data storage s = S.load();
        p = s._positions[user];
        int256 collateral = s.vault.locked(user, address(this));
        p.margin = collateral > 0 ? F.toUint(collateral) : 0;
    }

    function positionDebt(address user) external view returns (uint256) {
        S.Data storage s = S.load();
        int256 collateral = s.vault.locked(user, address(this));
        return collateral < 0 ? F.abs(collateral) : 0;
    }

    function curveAccounts() external view returns (uint256, int256, int256) {
        S.Data storage s = S.load();
        return (s._amm.curveBase, s._amm.entryCostNet, s.vault.ledger(address(this)).clearing);
    }

    function markPrice() external view returns (uint256) {
        S.Data storage s = S.load();
        return Curve.mark(s._amm);
    }

    function indexPrice() external view returns (uint256, uint64, bool) {
        S.Data storage s = S.load();
        return (s._index, s._indexBlock, s.externalIndex);
    }

    function config() external view returns (T.MarketConfig memory) {
        S.Data storage s = S.load();
        return s._config;
    }

    function status() external view returns (uint8, uint64) {
        S.Data storage s = S.load();
        return (uint8(s._config.status), s._config.statusSince);
    }

    function openInterest() external view returns (uint256, uint256, uint256) {
        S.Data storage s = S.load();
        uint256 mark = Curve.mark(s._amm);
        return (Math.mulDiv(s.longSize, mark, F.WAD), Math.mulDiv(s.shortSize, mark, F.WAD), Engine.oiCap(s));
    }

    function fundingRatePerBlock() public view returns (int256) {
        S.Data storage s = S.load();
        if (s._config.status >= T.Status.Settling) return 0;
        if (Engine.isDegraded(s) || s.pendingAdlCount != 0) return 0;
        return Engine.cachedRate(s);
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
        S.Data storage s = S.load();
        Engine.touch(s);
        Engine.refreshPrice(s, update, value);
        if (!s.guardianPaused && s.pendingAdlCount == 0) Engine.setStatus(s, T.Status.Active);
    }

    function pauseOpens() external nonReentrant {
        S.Data storage s = S.load();
        if (msg.sender != s.vault.guardian()) revert Unauthorized();
        Engine.touch(s);
        s.guardianPaused = true;
        Engine.setStatus(s, T.Status.Paused);
    }

    function resumeOpens() external nonReentrant {
        S.Data storage s = S.load();
        if (msg.sender != s.vault.governor()) revert Unauthorized();
        s.vault.requireOpenAllowed(address(this));
        Engine.touch(s);
        s.guardianPaused = false;
        Engine.setStatus(
            s, s.pendingAdlCount != 0 ? T.Status.Paused : Engine.isDegraded(s) ? T.Status.Degraded : T.Status.Active
        );
    }

    function claimCreatorFees() external nonReentrant {
        S.Data storage s = S.load();
        if (msg.sender != s._config.creator) revert Unauthorized();
        uint256 amount = s.vault.claimCreatorFees();
        emit CreatorFeesClaimed(address(this), msg.sender, amount);
    }

    function transferCreator(address to) external nonReentrant {
        S.Data storage s = S.load();
        if (msg.sender != s._config.creator) revert Unauthorized();
        if (to == address(0)) revert InvalidAddress();
        s._config.creator = to;
        s.vault.transferCreator(to);
        emit CreatorTransferred(msg.sender, to);
    }

    function reseed(uint256 depth) external nonReentrant {
        S.Data storage s = S.load();
        if (msg.sender != s._config.creator) revert Unauthorized();
        if (s.longSize != 0 || s.shortSize != 0) revert PositionExists();
        if (Curve.clearing(s._amm) != 0 || s.vault.ledger(address(this)).clearing != 0) revert AccountingInvariant();
        Engine.touch(s);
        s._amm = Curve.seed(Curve.mark(s._amm), depth);
        Engine.validateDepth(s, depth);
        s._twap.write(Curve.mark(s._amm), Engine.currentBlock());
    }
}
