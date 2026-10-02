// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Market} from "./Market.sol";
import {IMarginVault} from "./interfaces/IMarginVault.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {IPriceSource} from "./interfaces/IPriceSource.sol";
import {FixedPointMath as F} from "./libraries/FixedPointMath.sol";
import {RiskMath as Risk} from "./libraries/RiskMath.sol";
import {PripoTypes as T} from "./types/PripoTypes.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

interface IFactoryVault is IMarginVault {
    function token() external view returns (IERC20);
    function registerMarket(address market, address creator) external;
}

/// @notice Permissionless deterministic creation using approved code, bonded feeds and fixed launch risk sets.
contract MarketFactory is IMarketFactory, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant FEED_LISTING_BOND = 500e6;
    uint256 public constant LISTING_LOCK = 30 days;
    uint256 public constant GOVERNANCE_DELAY = 1 days;
    uint256 public constant MAX_SYMBOL_BYTES = 64;
    IFactoryVault public immutable vault;
    IERC20 public immutable token;
    address public immutable nullAdapter;
    bool public immutable slashToReserve;
    address public marketImplementation;
    address public pendingImplementation;
    uint256 public implementationReadyAt;
    mapping(address => bool) public allowedAdapters;
    mapping(address => uint256) public adapterReadyAt;
    mapping(address => mapping(bytes32 => bool)) public allowedFeeds;
    mapping(address => mapping(bytes32 => FeedListing)) public feedListings;
    mapping(address => mapping(bytes32 => address)) public marketForFeed;
    mapping(bytes32 => address) public marketForSymbol;
    mapping(address => bool) public isMarket;
    mapping(address => MarketRecord) public marketInfo;
    address[] public markets;
    uint256 public refundableBonds;
    uint256 public slashedBonds;

    struct FeedListing {
        address lister;
        uint64 refundAt;
        uint256 bond;
        bool slashed;
    }

    struct MarketRecord {
        address creator; // Original creator; the current transferable role is recorded by the vault.
        uint64 createdBlock;
        string symbol;
    }

    event AdapterScheduled(address indexed adapter, uint256 readyAt);
    event AdapterAllowed(address indexed adapter, bool allowed);
    event ImplementationScheduled(address indexed implementation, uint256 readyAt);
    event ImplementationChanged(address indexed previous, address indexed current);
    event ImplementationCancelled(address indexed implementation);
    event FeedListed(address indexed adapter, bytes32 indexed feedId, address indexed lister, uint256 refundAt);
    event FeedBondRefunded(address indexed adapter, bytes32 indexed feedId, address indexed lister, uint256 amount);
    event FeedSlashed(address indexed adapter, bytes32 indexed feedId, bytes32 indexed reason, uint256 amount);
    event SlashedBondsAllocated(uint256 amount, bool toReserve);

    error SymbolUnavailable(bytes32 symbolHash);
    error FeedUnavailable(address adapter, bytes32 feedId);
    error GovernanceNotReady(uint256 readyAt);
    error ListingNotRefundable();

    /// @param slashToReserve_ Immutable destination choice: protocol reserve (true) or global backstop (false).
    constructor(IFactoryVault vault_, address implementation_, address nullAdapter_, bool slashToReserve_) {
        if (address(vault_).code.length == 0 || implementation_.code.length == 0 || nullAdapter_.code.length == 0) {
            revert InvalidAddress();
        }
        vault = vault_;
        token = vault_.token();
        marketImplementation = implementation_;
        nullAdapter = nullAdapter_;
        slashToReserve = slashToReserve_;
        if (!IPriceSource(nullAdapter_).isSupported(0)) revert InvalidOracle();
        // Only kind/zero-price semantics are relevant for the canonical null source; it supplies no index.
        // slither-disable-next-line unused-return
        (uint256 price,,, bool externalIndex) = IPriceSource(nullAdapter_).getPrice(0, "");
        if (price != 0 || externalIndex) revert InvalidOracle();
    }

    modifier onlyGovernor() {
        if (msg.sender != vault.governor()) revert Unauthorized();
        _;
    }

    function createMarket(T.CreateParams calldata p) external nonReentrant returns (address) {
        return _create(p, "", 0);
    }

    /// @notice Optional pull update before initialization, forwarding the caller's exact native oracle fee.
    function createMarket(T.CreateParams calldata p, bytes calldata update)
        external
        payable
        nonReentrant
        returns (address)
    {
        return _create(p, update, msg.value);
    }

    // Both entry points hold nonReentrant through approved-adapter, token and vault callbacks. All mutating
    // factory entry points share the guard; registry views cannot authorize a second creation. Callback tested.
    // slither-disable-next-line reentrancy-eth,reentrancy-benign
    function _create(T.CreateParams calldata p, bytes memory update, uint256 value) private returns (address market) {
        bytes memory symbol = bytes(p.symbol);
        if (symbol.length == 0 || symbol.length > MAX_SYMBOL_BYTES) revert InvalidConfiguration();
        bytes32 salt = keccak256(symbol);
        if (marketForSymbol[salt] != address(0)) revert SymbolUnavailable(salt);
        bool externalIndex = p.priceSource != nullAdapter;
        if (externalIndex) {
            if (
                !allowedAdapters[p.priceSource] || !allowedFeeds[p.priceSource][p.feedId]
                    || marketForFeed[p.priceSource][p.feedId] != address(0)
            ) revert FeedUnavailable(p.priceSource, p.feedId);
            if (update.length != 0 || value != 0) {
                // The initialized market validates the cached observation again, including confidence and age.
                // slither-disable-next-line unused-return
                IPriceSource(p.priceSource).getPrice{value: value}(p.feedId, update);
            }
        } else {
            if (p.feedId != bytes32(0) || update.length != 0) revert InvalidOracle();
            if (value != 0) revert UnexpectedValue();
            if (p.initialPrice == 0 || p.initialPrice > 1e28) revert InvalidOracle();
        }
        uint256 minimum = externalIndex ? 5_000e6 : 2_000e6;
        if (p.seedBond < minimum) revert InsufficientInsurance(F.usdcToWad(p.seedBond), F.usdcToWad(minimum));
        market = Clones.cloneDeterministic(marketImplementation, salt);
        marketForSymbol[salt] = market;
        if (externalIndex) marketForFeed[p.priceSource][p.feedId] = market;
        isMarket[market] = true;
        markets.push(market);
        marketInfo[market] = MarketRecord(msg.sender, SafeCast.toUint64(block.number), p.symbol);
        vault.registerMarket(market, msg.sender);
        _receive(p.seedBond);
        token.forceApprove(address(vault), p.seedBond);
        vault.deposit(p.seedBond);
        vault.fundInsurance(market, F.usdcToWad(p.seedBond));
        Market(market)
            .initialize(
                vault, p.feedId, externalIndex, launchConfig(msg.sender, p.priceSource), p.initialPrice, p.depth
            );
        emit MarketCreated(market, msg.sender, p.symbol, externalIndex, p.depth, p.seedBond);
    }

    function predictAddress(string calldata symbol) external view returns (address) {
        bytes32 salt = keccak256(bytes(symbol));
        address existing = marketForSymbol[salt];
        return existing != address(0)
            ? existing
            : Clones.predictDeterministicAddress(marketImplementation, salt, address(this));
    }

    function marketCount() external view returns (uint256) {
        return markets.length;
    }

    function launchConfig(address creator, address source) public view returns (T.MarketConfig memory c) {
        bool externalIndex = source != nullAdapter;
        c.priceSource = source;
        c.creator = creator;
        c.takerFeeBps = 8;
        c.creatorShareBps = 3000;
        c.insuranceShareBps = 3000;
        c.referralShareBps = 1000;
        c.maxLeverageX = externalIndex ? 5 : 2;
        c.mmrBps = externalIndex ? 250 : 1500;
        c.liqPenaltyBps = 150;
        c.receiveCapX = 10;
        c.sideCapBps = Risk.sideCapBps(c.maxLeverageX);
        c.impactMarginBps = 10_000;
        c.maxOracleAgeBlocks = 10;
        c.degradeAfterBlocks = 100;
        c.degradedTwapBlocks = 600;
        c.fundingCapPerBlock = SafeCast.toUint64((externalIndex ? uint256(0.001e18) : uint256(0.005e18)) / 12_000);
        c.adlPendingWindow = 1000;
        c.maxPositionsPerMarket = 128;
    }

    function scheduleAdapter(address adapter) external nonReentrant onlyGovernor {
        if (adapter.code.length == 0 || adapter == nullAdapter || allowedAdapters[adapter]) revert InvalidAddress();
        adapterReadyAt[adapter] = block.timestamp + GOVERNANCE_DELAY;
        emit AdapterScheduled(adapter, adapterReadyAt[adapter]);
    }

    function activateAdapter(address adapter) external nonReentrant {
        uint256 ready = adapterReadyAt[adapter];
        if (ready == 0 || block.timestamp < ready) revert GovernanceNotReady(ready);
        delete adapterReadyAt[adapter];
        allowedAdapters[adapter] = true;
        emit AdapterAllowed(adapter, true);
    }

    function disableAdapter(address adapter) external nonReentrant {
        if (msg.sender != vault.governor() && msg.sender != vault.guardian()) revert Unauthorized();
        delete adapterReadyAt[adapter];
        allowedAdapters[adapter] = false;
        emit AdapterAllowed(adapter, false);
    }

    function listFeed(address adapter, bytes32 feedId) external nonReentrant {
        if (
            !allowedAdapters[adapter] || feedId == bytes32(0) || feedListings[adapter][feedId].lister != address(0)
                || !IPriceSource(adapter).isSupported(feedId)
        ) revert FeedUnavailable(adapter, feedId);
        uint64 at = SafeCast.toUint64(block.timestamp + LISTING_LOCK);
        feedListings[adapter][feedId] = FeedListing(msg.sender, at, FEED_LISTING_BOND, false);
        allowedFeeds[adapter][feedId] = true;
        refundableBonds += FEED_LISTING_BOND;
        _receive(FEED_LISTING_BOND);
        emit FeedListed(adapter, feedId, msg.sender, at);
    }

    /// @notice Refund only the original lister; permissionless callers cannot redirect the bond.
    function refundFeedBond(address adapter, bytes32 feedId) external nonReentrant {
        FeedListing storage listing = feedListings[adapter][feedId];
        uint256 amount = listing.bond;
        if (listing.lister == address(0) || listing.slashed || amount == 0 || block.timestamp < listing.refundAt) {
            revert ListingNotRefundable();
        }
        listing.bond = 0;
        refundableBonds -= amount;
        token.safeTransfer(listing.lister, amount);
        emit FeedBondRefunded(adapter, feedId, listing.lister, amount);
    }

    /// @notice Revoke a misconfigured feed and subordinate any still-escrowed listing bond. No market is reopened.
    function slashFeed(address adapter, bytes32 feedId, bytes32 reason) external nonReentrant onlyGovernor {
        FeedListing storage listing = feedListings[adapter][feedId];
        if (listing.lister == address(0) || listing.slashed || reason == bytes32(0)) revert InvalidConfiguration();
        allowedFeeds[adapter][feedId] = false;
        listing.slashed = true;
        uint256 amount = listing.bond;
        listing.bond = 0;
        refundableBonds -= amount;
        slashedBonds += amount;
        emit FeedSlashed(adapter, feedId, reason, amount);
    }

    /// @notice Batched separately so a vault allocation/deposit limit cannot block feed revocation.
    function allocateSlashedBonds(uint256 rawUsdc) external nonReentrant {
        if (rawUsdc == 0 || rawUsdc > slashedBonds) revert InvalidConfiguration();
        slashedBonds -= rawUsdc;
        token.forceApprove(address(vault), rawUsdc);
        if (slashToReserve) {
            vault.fundProtocolReserve(rawUsdc);
        } else {
            vault.deposit(rawUsdc);
            vault.fundBackstop(F.usdcToWad(rawUsdc));
        }
        emit SlashedBondsAllocated(rawUsdc, slashToReserve);
    }

    function scheduleImplementation(address implementation) external nonReentrant onlyGovernor {
        if (implementation.code.length == 0 || implementation == marketImplementation) revert InvalidAddress();
        pendingImplementation = implementation;
        implementationReadyAt = block.timestamp + GOVERNANCE_DELAY;
        emit ImplementationScheduled(implementation, implementationReadyAt);
    }

    function activateImplementation() external nonReentrant {
        uint256 ready = implementationReadyAt;
        if (ready == 0 || block.timestamp < ready) revert GovernanceNotReady(ready);
        address previous = marketImplementation;
        marketImplementation = pendingImplementation;
        delete pendingImplementation;
        delete implementationReadyAt;
        emit ImplementationChanged(previous, marketImplementation);
    }

    function cancelImplementation() external nonReentrant {
        if (msg.sender != vault.governor() && msg.sender != vault.guardian()) revert Unauthorized();
        emit ImplementationCancelled(pendingImplementation);
        delete pendingImplementation;
        delete implementationReadyAt;
    }

    function _receive(uint256 amount) private {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) != before + amount) revert UnsupportedToken();
    }
}
