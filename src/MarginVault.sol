// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IInsuranceBackstop} from "./interfaces/IInsuranceBackstop.sol";
import {IMarginVault} from "./interfaces/IMarginVault.sol";
import {IMarketCore} from "./interfaces/IMarketCore.sol";
import {FixedPointMath as F} from "./libraries/FixedPointMath.sol";
import {PripoTypes as T} from "./types/PripoTypes.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Heap} from "@openzeppelin/contracts/utils/structs/Heap.sol";

/// @notice Isolated collateral custody. Registered market code is trusted to authorize each user action.
/// @dev Every internal credit has an explicit debit. No aggregate counter is written on the trade path.
contract MarginVault is IMarginVault, Initializable, UUPSUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Heap for Heap.Uint256Heap;

    uint256 public constant MIN_PROTOCOL_RESERVE = 10_000e18;
    uint256 public constant RESERVE_BLOCKS = 96_000;
    uint256 public constant MAX_ALLOCATION_ENTRIES = 32;
    uint256 public constant MAX_TERMINAL_ACCOUNTS = 256;

    IERC20 public token;
    address public governor;
    address public guardian;
    address public treasury;
    uint256 public depositCap;
    mapping(address => bool) public registrars;
    mapping(address => address) public registrarOf;
    mapping(address => address) public creatorOf;
    mapping(address => uint256) public freeBalance;
    mapping(address => mapping(address => int256)) public locked;
    mapping(address => T.Ledger) private _ledgers;
    mapping(address => mapping(address => T.OperatorPolicy)) public operators;
    mapping(bytes32 => address) public referralOwner;
    mapping(address => bytes32) public referralCode;
    mapping(address => address) public referrerOf;
    mapping(address => uint256) public referralOwed;
    address public pendingImplementation;
    bytes32 public upgradeDataHash;
    uint256 public upgradeReadyAt;
    // Appended fields preserve the existing UUPS vault storage layout.
    uint256 public backstopBalance;
    IInsuranceBackstop public backstopController;
    // Append-only capital accounts. Aggregate controls are not additional terms in the cash identity.
    uint256 public protocolReserve;
    uint256 public totalDeficit;
    uint256 public aggregateReserveBudget;
    mapping(address => uint256) public reserveBudget;
    mapping(address => bool) public terminalFinalized;
    mapping(address => uint256) public deficit;
    mapping(address => uint256) public deficitCreatedAt;
    Heap.Uint256Heap private _deficitQueue;
    mapping(address => bool) public marketAdmitted;
    // Append-only pending coverage. The total is a per-market control aggregate, not extra cash.
    mapping(address => mapping(address => T.AdlReservation)) private _adlReservations;
    mapping(address => uint256) public adlReservedTotal;
    mapping(address => uint256) public adlReservationCount;

    event RegistrarSet(address indexed registrar, bool allowed);
    event UpgradeScheduled(address indexed implementation, bytes32 dataHash, uint256 readyAt);
    event UpgradeCancelled(address indexed implementation);

    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize through an ERC1967 proxy, atomically with proxy creation.
    function initialize(address token_, address governor_, address guardian_, address treasury_) external initializer {
        if (token_.code.length == 0 || governor_ == address(0) || guardian_ == address(0) || treasury_ == address(0)) {
            revert InvalidAddress();
        }
        if (IERC20Metadata(token_).decimals() != 6) revert UnsupportedToken();
        token = IERC20(token_);
        governor = governor_;
        guardian = guardian_;
        treasury = treasury_;
        depositCap = 100_000e6;
        registrars[governor_] = true;
    }

    modifier onlyGovernor() {
        if (msg.sender != governor) revert Unauthorized();
        _;
    }
    modifier onlyMarket() {
        if (registrarOf[msg.sender] == address(0)) revert Unauthorized();
        _;
    }

    function setRegistrar(address registrar, bool allowed) external onlyGovernor {
        if (registrar == address(0)) revert InvalidAddress();
        registrars[registrar] = allowed;
        emit RegistrarSet(registrar, allowed);
    }

    /// @dev Registration is permanent: removing an active market would strand its collateral.
    function registerMarket(address market, address creator) external {
        if (!registrars[msg.sender]) revert Unauthorized();
        if (market.code.length == 0 || creator == address(0)) revert InvalidAddress();
        if (registrarOf[market] != address(0)) revert InvalidConfiguration();
        registrarOf[market] = msg.sender;
        creatorOf[market] = creator;
        emit MarketRegistered(market, creator, msg.sender);
    }

    function ledger(address market) external view returns (T.Ledger memory) {
        return _ledgers[market];
    }

    function reserveFloor() public view returns (uint256) {
        return Math.max(MIN_PROTOCOL_RESERVE, aggregateReserveBudget);
    }

    /// @notice Reserve the admitted ceiling, irrespective of current insurance, open interest or pause state.
    /// @dev Trusted immutable market code supplies its validated launch parameters. Admission is permanent until settlement.
    function admitMarket(uint256 oiCap, uint64 fundingCapPerBlock) external nonReentrant onlyMarket {
        if (marketAdmitted[msg.sender] || terminalFinalized[msg.sender]) revert InvalidConfiguration();
        if (oiCap == 0) revert InvalidConfiguration();
        uint256 budget = Math.mulDiv(oiCap, uint256(fundingCapPerBlock) * RESERVE_BLOCKS, F.WAD, Math.Rounding.Ceil);
        reserveBudget[msg.sender] = budget;
        marketAdmitted[msg.sender] = true;
        aggregateReserveBudget += budget;
        requireOpenAllowed(msg.sender);
        emit ReserveBudgetAdmitted(msg.sender, oiCap, fundingCapPerBlock, budget);
    }

    function requireOpenAllowed(address market) public view {
        if (!marketAdmitted[market] || terminalFinalized[market]) revert MarketNotAdmitted();
        if (totalDeficit != 0) revert ProtocolDeficit(totalDeficit);
        uint256 floor = reserveFloor();
        if (protocolReserve < floor) revert ReserveBelowFloor(protocolReserve, floor);
    }

    /// @notice Irrevocable real-USDC contribution: oldest deficits first, then reserve. Bypasses the user deposit cap.
    /// @dev At most 32 queue entries per call; an oversized contribution reverts atomically. Allocate fees to prune
    ///      cleared queue entries, or split contributions into smaller amounts, before retrying.
    function fundProtocolReserve(uint256 usdc) external nonReentrant {
        _receiveCapital(usdc);
        _allocateContribution(F.usdcToWad(usdc));
    }

    /// @notice Repay a selected terminal deficit; excess follows global deficit priority before entering reserve.
    function recapitalize(address market, uint256 usdc) external nonReentrant {
        if (deficit[market] == 0) revert InvalidTerminalState();
        _receiveCapital(usdc);
        uint256 amount = F.usdcToWad(usdc);
        uint256 repaid = Math.min(amount, deficit[market]);
        _repayDeficit(market, repaid, 2);
        _allocateContribution(amount - repaid);
    }

    /// @notice Irrevocably donate existing free collateral to a terminal deficit, with no token inflow or user credit.
    function contributeToDeficit(address market, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > deficit[market]) revert InvalidTerminalState();
        _debitFree(msg.sender, amount);
        _repayDeficit(market, amount, 2);
    }

    /// @notice Allocate accrued fees without a token transfer. Unprocessed fees stay in their originating ledger.
    /// @dev maxEntries bounds queue processing, including entries already cleared by targeted recapitalization.
    function allocateProtocolFees(address market, uint256 maxEntries)
        external
        nonReentrant
        returns (uint256 repaid, uint256 reserved)
    {
        if (registrarOf[market] == address(0)) revert Unauthorized();
        if (maxEntries == 0 || maxEntries > MAX_ALLOCATION_ENTRIES) revert AllocationLimit();
        T.Ledger storage l = _ledgers[market];
        repaid = _repayOldest(l.protocolOwed, maxEntries, 1);
        l.protocolOwed -= repaid;
        uint256 floor = reserveFloor();
        if (totalDeficit == 0 && protocolReserve < floor) {
            reserved = Math.min(l.protocolOwed, floor - protocolReserve);
            l.protocolOwed -= reserved;
            _addReserve(reserved, 1);
        }
        emit ProtocolFeesAllocated(market, repaid, reserved);
    }

    /// @notice Queue inspection for bounded allocation keepers; cleared entries may remain until a later allocation.
    function deficitQueueHead() external view returns (address market, uint256 entries) {
        entries = _deficitQueue.length();
        if (entries != 0) market = address(uint160(_deficitQueue.peek()));
    }

    /// @notice Finish terminal custody after the market has realized all PnL/funding and applied eligible profit haircuts.
    /// @dev This is not the price/position settlement engine. Trusted registered code supplies the complete debtor list,
    ///      sets Settled with both aggregate sizes zero, and calls this once in the same atomic transaction.
    function finalizeSettlement(address[] calldata debtors)
        external
        nonReentrant
        onlyMarket
        returns (uint256 uncovered)
    {
        if (
            terminalFinalized[msg.sender] || debtors.length > MAX_TERMINAL_ACCOUNTS
                || adlReservationCount[msg.sender] != 0
        ) {
            revert InvalidTerminalState();
        }
        IMarketCore market = IMarketCore(msg.sender);
        // The state is required; its transition block is irrelevant once the whole book is closed.
        // slither-disable-next-line unused-return
        (uint8 state,) = market.status();
        if (state != uint8(T.Status.Settled) || market.longSize() != 0 || market.shortSize() != 0) {
            revert InvalidTerminalState();
        }
        terminalFinalized[msg.sender] = true;
        for (uint256 i; i < debtors.length; ++i) {
            int256 collateral = locked[debtors[i]][msg.sender];
            if (collateral < 0) {
                uncovered += F.abs(collateral);
                locked[debtors[i]][msg.sender] = 0;
            }
        }
        T.Ledger storage l = _ledgers[msg.sender];
        // TWAP settlement of net virtual exposure can leave either sign of clearing. Net it exactly once:
        // removing negative collateral adds isolatedDebt to the cash sum; removing clearing subtracts clearing.
        // A positive net balance is insurance; a negative one must use the terminal funding waterfall.
        int256 clearing = l.clearing;
        emit TerminalClearingNetted(msg.sender, clearing, uncovered);
        if (clearing >= 0) {
            uint256 available = F.toUint(clearing);
            if (available > uncovered) {
                l.insurance += available - uncovered;
                uncovered = 0;
            } else {
                uncovered -= available;
            }
        } else {
            uncovered += F.abs(clearing);
        }
        l.clearing = 0;
        uint256 used = _terminalUse(uncovered, l.insurance, 0);
        l.insurance -= used;
        uncovered -= used;
        used = _terminalUse(uncovered, l.creatorOwed, 3);
        l.creatorOwed -= used;
        uncovered -= used;
        used = _terminalUse(uncovered, l.protocolOwed, 4);
        l.protocolOwed -= used;
        uncovered -= used;
        // A terminal draw spends actual vault capital, without calling the live controller or changing its window.
        used = _terminalUse(uncovered, backstopBalance, 5);
        backstopBalance -= used;
        uncovered -= used;
        used = _terminalUse(uncovered, protocolReserve, 6);
        if (used != 0) {
            uint256 previous = protocolReserve;
            protocolReserve -= used;
            emit ProtocolReserveChanged(previous, protocolReserve, 2);
        }
        uncovered -= used;
        if (uncovered != 0) {
            deficit[msg.sender] = uncovered;
            totalDeficit += uncovered;
            deficitCreatedAt[msg.sender] = block.timestamp;
            uint256 key = (uint256(SafeCast.toUint96(block.timestamp)) << 160) | uint160(msg.sender);
            _deficitQueue.insert(key);
            emit DeficitChanged(msg.sender, 0, uncovered, 0);
            emit TerminalCoverage(msg.sender, 7, uncovered);
        }
        uint256 budget = reserveBudget[msg.sender];
        aggregateReserveBudget -= budget;
        delete reserveBudget[msg.sender];
        emit ReserveBudgetRetired(msg.sender, budget);
    }

    function deposit(uint256 usdc) external nonReentrant {
        if (usdc == 0) revert ZeroAmount();
        uint256 beforeCash = token.balanceOf(address(this));
        if (beforeCash + usdc > depositCap) revert DepositCapExceeded();
        token.safeTransferFrom(msg.sender, address(this), usdc);
        if (token.balanceOf(address(this)) != beforeCash + usdc) revert UnsupportedToken();
        freeBalance[msg.sender] += F.usdcToWad(usdc);
        emit Deposited(msg.sender, usdc);
    }

    function withdraw(uint256 usdc) external nonReentrant {
        if (usdc == 0) revert ZeroAmount();
        _debitFree(msg.sender, F.usdcToWad(usdc));
        token.safeTransfer(msg.sender, usdc);
        emit Withdrawn(msg.sender, usdc);
    }

    function fundInsurance(address market, uint256 amount) external {
        if (registrarOf[market] == address(0)) revert Unauthorized();
        if (amount == 0) revert ZeroAmount();
        _debitFree(msg.sender, amount);
        _ledgers[market].insurance += amount;
        emit InsuranceFunded(market, msg.sender, amount);
    }

    function lock(address user, uint256 amount) external onlyMarket {
        _debitFree(user, amount);
        locked[user][msg.sender] += F.toInt(amount);
    }

    function release(address user, uint256 amount) external onlyMarket {
        int256 collateral = locked[user][msg.sender];
        if (collateral < F.toInt(amount)) revert InsufficientMargin(collateral > 0 ? F.toUint(collateral) : 0, amount);
        locked[user][msg.sender] = collateral - F.toInt(amount);
        freeBalance[user] += amount;
    }

    function settlePnl(address user, int256 pnl) external onlyMarket {
        locked[user][msg.sender] += pnl;
        _ledgers[msg.sender].clearing -= pnl;
    }

    function settleFunding(address user, int256 owed) external onlyMarket {
        locked[user][msg.sender] -= owed;
        _ledgers[msg.sender].fundingPool += owed;
    }

    function chargeFee(address user, T.FeeBreakdown calldata fee, bool fromLocked) external onlyMarket {
        if (fee.total != fee.protocol + fee.creator + fee.insurance + fee.referral) revert AccountingInvariant();
        address referrer = referrerOf[user];
        if (referrer == address(0) && fee.referral != 0) revert InvalidReferral();
        if (fromLocked) locked[user][msg.sender] -= F.toInt(fee.total);
        else _debitFree(user, fee.total);
        T.Ledger storage l = _ledgers[msg.sender];
        l.protocolOwed += fee.protocol;
        l.creatorOwed += fee.creator;
        l.insurance += fee.insurance;
        if (fee.referral != 0) referralOwed[referrer] += fee.referral;
    }

    function sweepFunding(uint256 amount) external onlyMarket {
        _ledgers[msg.sender].fundingPool -= F.toInt(amount);
        _ledgers[msg.sender].insurance += amount;
    }

    /// @notice Legacy insurance-only primitive. Current market code uses coverBadDebt for capped backstop coverage.
    function coverDebt(address user) external onlyMarket returns (uint256 amount) {
        int256 collateral = locked[user][msg.sender];
        if (collateral >= 0) return 0;
        amount = F.abs(collateral);
        T.Ledger storage l = _ledgers[msg.sender];
        if (l.insurance < amount) revert InsufficientInsurance(l.insurance, amount);
        l.insurance -= amount;
        locked[user][msg.sender] = 0;
    }

    /// @notice Bind the backstop controller once; replacing it requires the delayed vault upgrade path.
    function setBackstopController(IInsuranceBackstop controller) external onlyGovernor {
        if (address(backstopController) != address(0)) revert InvalidConfiguration();
        if (address(controller).code.length == 0 || controller.vault() != address(this)) revert InvalidAddress();
        backstopController = controller;
        emit BackstopControllerSet(address(controller));
    }

    function fundBackstop(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        _debitFree(msg.sender, amount);
        backstopBalance += amount;
        emit BackstopFunded(msg.sender, amount);
    }

    function moveInsuranceToBackstop(address market, uint256 amount) external {
        if (msg.sender != address(backstopController)) revert Unauthorized();
        _ledgers[market].insurance -= amount;
        backstopBalance += amount;
        emit InsuranceTransferredToBackstop(market, amount);
    }

    /// @notice Apply insurance, then the capped backstop; the market must resolve any returned remainder atomically.
    // The bound controller makes only static market/vault reads and updates its budget; no token transfer or callback.
    // The vault guard also rejects recursive coverage. Governor upgrades must preserve this controller trust boundary.
    // slither-disable-next-line reentrancy-no-eth,reentrancy-benign
    function coverBadDebt(address user)
        external
        nonReentrant
        onlyMarket
        returns (uint256 insurance, uint256 backstop, uint256 remaining)
    {
        int256 collateral = locked[user][msg.sender];
        if (collateral >= 0) return (0, 0, 0);
        return _coverLiquidationLoss(user, F.abs(collateral));
    }

    function liveCoverage(address market) external view returns (uint256 insurance, uint256 backstop) {
        insurance = _ledgers[market].insurance;
        if (address(backstopController) != address(0)) backstop = backstopController.capacity(market);
    }

    function adlReservation(address market, address user) external view returns (T.AdlReservation memory) {
        return _adlReservations[market][user];
    }

    function adlReserved(address market, address user) external view returns (uint256) {
        T.AdlReservation storage r = _adlReservations[market][user];
        return r.lossCoverage + r.allowanceFromCoverage + r.allowanceFromReserve;
    }

    /// @notice Move live coverage into an isolated reservation and fund its lifetime dust allowance once.
    /// @dev The trusted market supplies its validated book cap. The controller consumes the live window here,
    ///      never on a continuation. Returned backstop coverage becomes local insurance; the window is not reset.
    // The bound controller only reads market/vault state before updating its window. No tokens are transferred.
    // slither-disable-next-line reentrancy-no-eth,reentrancy-benign
    function reserveAdl(address user, uint256 roundingTarget)
        external
        nonReentrant
        onlyMarket
        returns (uint256 coverage, uint256 roundingFromCoverage, uint256 roundingFromReserve)
    {
        if (user == address(0) || roundingTarget == 0 || terminalFinalized[msg.sender]) {
            revert InvalidConfiguration();
        }
        T.AdlReservation storage r = _adlReservations[msg.sender][user];
        if (r.active) revert AdlAlreadyPending();
        coverage = _ledgers[msg.sender].insurance;
        _ledgers[msg.sender].insurance = 0;
        if (address(backstopController) != address(0) && backstopBalance != 0) {
            uint256 amount = backstopController.consume(msg.sender, backstopBalance);
            if (amount > backstopBalance) revert AccountingInvariant();
            backstopBalance -= amount;
            coverage += amount;
        }
        roundingFromCoverage = Math.min(coverage, roundingTarget);
        roundingFromReserve = Math.min(protocolReserve, roundingTarget - roundingFromCoverage);
        if (roundingFromReserve != 0) {
            uint256 previous = protocolReserve;
            protocolReserve -= roundingFromReserve;
            emit ProtocolReserveChanged(previous, protocolReserve, 3);
        }
        r.lossCoverage = coverage - roundingFromCoverage;
        r.allowanceFromCoverage = roundingFromCoverage;
        r.allowanceFromReserve = roundingFromReserve;
        r.active = true;
        ++adlReservationCount[msg.sender];
        adlReservedTotal[msg.sender] += coverage + roundingFromReserve;
        emit AdlReserved(msg.sender, user, coverage, roundingFromReserve);
    }

    /// @notice Credit only this pending loser's locked collateral from its loss-coverage partition.
    function consumeAdlCoverage(address user, uint256 amount) external onlyMarket {
        T.AdlReservation storage r = _adlReservations[msg.sender][user];
        if (!r.active) revert NoPendingAdl();
        if (amount > r.lossCoverage) revert AccountingInvariant();
        r.lossCoverage -= amount;
        r.consumedCoverage += amount;
        adlReservedTotal[msg.sender] -= amount;
        locked[user][msg.sender] += F.toInt(amount);
        emit AdlCoverageConsumed(msg.sender, user, amount);
    }

    /// @notice Reverse provisional coverage made unnecessary by later realizable relief. No loser refund occurs.
    function restoreAdlCoverage(address user, uint256 amount) external onlyMarket {
        T.AdlReservation storage r = _adlReservations[msg.sender][user];
        if (!r.active) revert NoPendingAdl();
        if (amount > r.consumedCoverage) revert AccountingInvariant();
        r.consumedCoverage -= amount;
        r.lossCoverage += amount;
        adlReservedTotal[msg.sender] += amount;
        locked[user][msg.sender] -= F.toInt(amount);
        emit AdlCoverageRestored(msg.sender, user, amount);
    }

    /// @notice Return unspent loss coverage replaced by a margin addition. Rounding partitions stay reserved.
    function returnAdlCoverage(address user, uint256 amount) external onlyMarket {
        T.AdlReservation storage r = _adlReservations[msg.sender][user];
        if (!r.active) revert NoPendingAdl();
        if (amount > r.lossCoverage) revert AccountingInvariant();
        r.lossCoverage -= amount;
        adlReservedTotal[msg.sender] -= amount;
        _ledgers[msg.sender].insurance += amount;
        emit AdlCoverageReturned(msg.sender, user, amount);
    }

    /// @notice Pay one quote wei outside paired PnL. Exhaustion returns false without touching loss coverage.
    function payAdlRounding(address user, address winner) external onlyMarket returns (bool paid) {
        if (winner == address(0) || winner == user) revert InvalidAddress();
        T.AdlReservation storage r = _adlReservations[msg.sender][user];
        if (!r.active) revert NoPendingAdl();
        if (r.allowanceFromCoverage != 0) --r.allowanceFromCoverage;
        else if (r.allowanceFromReserve != 0) --r.allowanceFromReserve;
        else return false;
        --adlReservedTotal[msg.sender];
        ++freeBalance[winner];
        emit AdlRoundingPaid(msg.sender, user, winner);
        return true;
    }

    /// @notice Return unused local/backstop coverage to insurance and unused reserve allowance to reserve.
    function releaseAdlReservation(address user) external onlyMarket returns (uint256 returned) {
        T.AdlReservation memory r = _adlReservations[msg.sender][user];
        if (!r.active) revert NoPendingAdl();
        uint256 insurance = r.lossCoverage + r.allowanceFromCoverage;
        returned = insurance + r.allowanceFromReserve;
        delete _adlReservations[msg.sender][user];
        --adlReservationCount[msg.sender];
        adlReservedTotal[msg.sender] -= returned;
        _ledgers[msg.sender].insurance += insurance;
        _addReserve(r.allowanceFromReserve, 4);
        emit AdlReservationReleased(msg.sender, user, insurance, r.allowanceFromReserve);
    }

    /// @notice Fund the planned loss of a closed portion without consuming the remaining portion's collateral.
    /// @dev Trusted market code proves the amount from the paired fill and allocated margin. Uses live claim caps.
    // The guarded, governor-bound controller only performs static vault/market reads before consuming its budget.
    // slither-disable-next-line reentrancy-no-eth,reentrancy-benign
    function coverLiquidationLoss(address user, uint256 amount)
        external
        nonReentrant
        onlyMarket
        returns (uint256 insurance, uint256 backstop, uint256 remaining)
    {
        return _coverLiquidationLoss(user, amount);
    }

    // Both external entry points hold nonReentrant; the bound controller makes only static reads of this vault.
    // slither-disable-next-line reentrancy-benign
    function _coverLiquidationLoss(address user, uint256 debt)
        private
        returns (uint256 insurance, uint256 backstop, uint256 remaining)
    {
        T.Ledger storage l = _ledgers[msg.sender];
        insurance = Math.min(debt, l.insurance);
        l.insurance -= insurance;
        remaining = debt - insurance;
        if (remaining != 0 && address(backstopController) != address(0)) {
            backstop = backstopController.consume(msg.sender, remaining);
            if (backstop > remaining || backstop > backstopBalance) revert AccountingInvariant();
            backstopBalance -= backstop;
            remaining -= backstop;
        }
        locked[user][msg.sender] += F.toInt(insurance + backstop);
        emit DebtCovered(msg.sender, user, insurance, backstop);
    }

    /// @notice Penalties consume positive collateral only. Insurance cannot subsidize liquidation rewards.
    function chargeLiquidationPenalty(address user, address liquidator, uint256 nominal)
        external
        onlyMarket
        returns (uint256 amount)
    {
        if (liquidator == address(0)) revert InvalidAddress();
        int256 collateral = locked[user][msg.sender];
        if (collateral <= 0) return 0;
        amount = Math.min(nominal, F.toUint(collateral));
        uint256 reward = Math.mulDiv(amount, 4000, F.BPS);
        locked[user][msg.sender] = collateral - F.toInt(amount);
        freeBalance[liquidator] += reward;
        _ledgers[msg.sender].insurance += amount - reward;
        emit LiquidationPenaltyPaid(msg.sender, user, liquidator, amount, reward);
    }

    /// @notice Transfer only locked collateral in this market; a donor's free balance cannot be clawed back.
    function transferAdlProfit(address donor, address debtor, uint256 amount) external onlyMarket {
        if (donor == debtor || amount == 0) revert InvalidConfiguration();
        int256 debit = F.toInt(amount);
        int256 donorMargin = locked[donor][msg.sender];
        int256 debtorMargin = locked[debtor][msg.sender];
        if (donorMargin < debit || debtorMargin >= 0 || amount > F.abs(debtorMargin)) revert AccountingInvariant();
        locked[donor][msg.sender] = donorMargin - debit;
        locked[debtor][msg.sender] = debtorMargin + debit;
        emit AdlProfitTransferred(msg.sender, donor, debtor, amount);
    }

    function claimCreatorFees() external nonReentrant onlyMarket returns (uint256 amount) {
        amount = _payableWad(_ledgers[msg.sender].creatorOwed);
        _ledgers[msg.sender].creatorOwed -= amount;
        if (amount != 0) token.safeTransfer(creatorOf[msg.sender], amount / F.USDC_SCALE);
    }

    function transferCreator(address to) external onlyMarket {
        if (to == address(0)) revert InvalidAddress();
        creatorOf[msg.sender] = to;
    }

    function claimProtocolFees(address market) external nonReentrant returns (uint256 amount) {
        if (totalDeficit != 0) revert ProtocolDeficit(totalDeficit);
        uint256 floor = reserveFloor();
        if (protocolReserve < floor) revert ReserveBelowFloor(protocolReserve, floor);
        amount = _payableWad(_ledgers[market].protocolOwed);
        _ledgers[market].protocolOwed -= amount;
        if (amount != 0) token.safeTransfer(treasury, amount / F.USDC_SCALE);
        emit ProtocolFeesClaimed(market, amount);
    }

    function setOperator(address op, T.OperatorPolicy calldata policy) external {
        if (op == address(0) || op == msg.sender) revert InvalidAddress();
        if (policy.expiry <= block.number || policy.maxNotionalPerTx == 0 || policy.maxTotalNotional == 0) {
            revert PolicyViolation(1);
        }
        operators[msg.sender][op] = policy;
        operators[msg.sender][op].usedNotional = 0;
        emit OperatorSet(msg.sender, op, policy.expiry, policy.maxTotalNotional);
    }

    function revokeOperator(address op) external {
        delete operators[msg.sender][op];
        emit OperatorRevoked(msg.sender, op);
    }

    /// @dev Leaf = keccak256(bytes.concat(keccak256(abi.encode(market)))); sorted-pair Merkle tree.
    function checkAndConsume(address user, address op, uint256 notional, bool isClose, bytes32[] calldata marketProof)
        external
        onlyMarket
    {
        if (user == address(0) || op == address(0)) revert InvalidAddress();
        if (!isClose) requireOpenAllowed(msg.sender);
        if (user == op) return;
        T.OperatorPolicy storage policy = operators[user][op];
        if (policy.expiry <= block.number) revert PolicyViolation(1);
        if (isClose && !policy.canClose) revert PolicyViolation(2);
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender))));
        if (policy.marketsRoot != bytes32(0) && !MerkleProof.verifyCalldata(marketProof, policy.marketsRoot, leaf)) {
            revert PolicyViolation(3);
        }
        if (notional > policy.maxNotionalPerTx) revert PolicyViolation(4);
        uint256 used = uint256(policy.usedNotional) + notional;
        if (used > policy.maxTotalNotional) revert PolicyViolation(5);
        policy.usedNotional = SafeCast.toUint128(used);
    }

    function registerReferralCode(bytes32 code) external {
        if (code == bytes32(0) || referralOwner[code] != address(0) || referralCode[msg.sender] != bytes32(0)) {
            revert InvalidReferral();
        }
        referralOwner[code] = msg.sender;
        referralCode[msg.sender] = code;
        emit ReferralRegistered(msg.sender, code);
    }

    function setReferrer(bytes32 code) external {
        address referrer = referralOwner[code];
        if (referrer == address(0) || referrer == msg.sender || referrerOf[msg.sender] != address(0)) {
            revert InvalidReferral();
        }
        referrerOf[msg.sender] = referrer;
        emit ReferrerSet(msg.sender, referrer);
    }

    function claimReferral() external nonReentrant {
        uint256 amount = _payableWad(referralOwed[msg.sender]);
        referralOwed[msg.sender] -= amount;
        if (amount != 0) token.safeTransfer(msg.sender, amount / F.USDC_SCALE);
        emit ReferralClaimed(msg.sender, amount);
    }

    /// @notice A 48-hour delay is enforced even if the governor is not itself a timelock.
    function scheduleUpgrade(address implementation, bytes32 dataHash) external onlyGovernor {
        if (implementation.code.length == 0) revert InvalidAddress();
        pendingImplementation = implementation;
        upgradeDataHash = dataHash;
        upgradeReadyAt = block.timestamp + 48 hours;
        emit UpgradeScheduled(implementation, dataHash, upgradeReadyAt);
    }

    function cancelUpgrade() external {
        if (msg.sender != governor && msg.sender != guardian) revert Unauthorized();
        emit UpgradeCancelled(pendingImplementation);
        delete pendingImplementation;
        delete upgradeDataHash;
        delete upgradeReadyAt;
    }

    function upgradeToAndCall(address implementation, bytes memory data) public payable override {
        if (msg.value != 0) revert UnexpectedValue();
        if (keccak256(data) != upgradeDataHash) revert UpgradeNotReady();
        super.upgradeToAndCall(implementation, data);
    }

    function _authorizeUpgrade(address implementation) internal override onlyGovernor {
        // Timestamp is used only for the wall-clock governance delay; market timing uses blocks.
        if (implementation != pendingImplementation || upgradeReadyAt == 0 || block.timestamp < upgradeReadyAt) {
            revert UpgradeNotReady();
        }
        delete pendingImplementation;
        delete upgradeDataHash;
        delete upgradeReadyAt;
    }

    function _debitFree(address user, uint256 amount) private {
        uint256 available = freeBalance[user];
        if (available < amount) revert InsufficientMargin(available, amount);
        freeBalance[user] = available - amount;
    }

    function _receiveCapital(uint256 usdc) private {
        if (usdc == 0) revert ZeroAmount();
        uint256 beforeCash = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), usdc);
        if (token.balanceOf(address(this)) != beforeCash + usdc) revert UnsupportedToken();
        emit ProtocolCapitalFunded(msg.sender, usdc);
    }

    function _allocateContribution(uint256 amount) private {
        if (amount == 0) return;
        amount -= _repayOldest(amount, MAX_ALLOCATION_ENTRIES, 2);
        if (amount != 0) {
            if (totalDeficit != 0) revert AllocationLimit();
            _addReserve(amount, 0);
        }
    }

    function _addReserve(uint256 amount, uint8 reason) private {
        if (amount == 0) return;
        uint256 previous = protocolReserve;
        protocolReserve += amount;
        emit ProtocolReserveChanged(previous, protocolReserve, reason);
    }

    function _repayOldest(uint256 available, uint256 maxEntries, uint8 reason) private returns (uint256 repaid) {
        for (uint256 i; i < maxEntries && _deficitQueue.length() != 0; ++i) {
            address market = address(uint160(_deficitQueue.peek()));
            uint256 owed = deficit[market];
            if (owed != 0) {
                if (available == 0) break;
                uint256 amount = Math.min(available, owed);
                _repayDeficit(market, amount, reason);
                repaid += amount;
                available -= amount;
                if (amount != owed) break;
            }
            // The root was already read above. Removal must retain the same minimum comparator as insertion.
            // slither-disable-next-line unused-return
            _deficitQueue.pop();
        }
    }

    function _repayDeficit(address market, uint256 amount, uint8 reason) private {
        uint256 previous = deficit[market];
        deficit[market] = previous - amount;
        totalDeficit -= amount;
        emit DeficitChanged(market, previous, previous - amount, reason);
    }

    function _terminalUse(uint256 debt, uint256 available, uint8 source) private returns (uint256 used) {
        used = Math.min(debt, available);
        if (used != 0) emit TerminalCoverage(msg.sender, source, used);
    }

    function _payableWad(uint256 amount) private pure returns (uint256) {
        return amount - amount % F.USDC_SCALE;
    }
}
