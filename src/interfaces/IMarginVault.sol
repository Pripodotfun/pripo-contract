// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PripoTypes as T} from "../types/PripoTypes.sol";
import {IPripoErrors} from "./IPripoErrors.sol";

/// @notice USDC custody and balanced accounting. Token amounts are raw USDC; ledger amounts are WAD.
interface IMarginVault is IPripoErrors {
    event Deposited(address indexed user, uint256 usdc);
    event Withdrawn(address indexed user, uint256 usdc);
    event MarketRegistered(address indexed market, address indexed creator, address indexed registrar);
    event InsuranceFunded(address indexed market, address indexed user, uint256 amount);
    event OperatorSet(address indexed user, address indexed operator, uint64 expiry, uint128 maxTotalNotional);
    event OperatorRevoked(address indexed user, address indexed operator);
    event ReferralRegistered(address indexed user, bytes32 indexed code);
    event ReferrerSet(address indexed user, address indexed referrer);
    event ReferralClaimed(address indexed referrer, uint256 amount);
    event BackstopFunded(address indexed user, uint256 amount);
    event BackstopControllerSet(address indexed controller);
    event InsuranceTransferredToBackstop(address indexed market, uint256 amount);
    event DebtCovered(address indexed market, address indexed user, uint256 insurance, uint256 backstop);
    event LiquidationPenaltyPaid(
        address indexed market, address indexed user, address indexed liquidator, uint256 total, uint256 reward
    );
    event AdlProfitTransferred(address indexed market, address indexed donor, address indexed debtor, uint256 amount);
    event ReserveBudgetAdmitted(address indexed market, uint256 oiCap, uint64 fundingCapPerBlock, uint256 budget);
    event ReserveBudgetRetired(address indexed market, uint256 budget);
    event ProtocolReserveChanged(uint256 previous, uint256 current, uint8 reason);
    event DeficitChanged(address indexed market, uint256 previous, uint256 current, uint8 reason);
    event TerminalCoverage(address indexed market, uint8 source, uint256 amount);
    event ProtocolFeesAllocated(address indexed market, uint256 repaid, uint256 reserved);
    event ProtocolFeesClaimed(address indexed market, uint256 amount);
    event ProtocolCapitalFunded(address indexed contributor, uint256 usdc);
    event TerminalClearingNetted(address indexed market, int256 clearing, uint256 isolatedDebt);
    event AdlReserved(address indexed market, address indexed user, uint256 coverage, uint256 allowanceFromReserve);
    event AdlCoverageConsumed(address indexed market, address indexed user, uint256 amount);
    event AdlCoverageRestored(address indexed market, address indexed user, uint256 amount);
    event AdlCoverageReturned(address indexed market, address indexed user, uint256 amount);
    event AdlRoundingPaid(address indexed market, address indexed user, address indexed winner);
    event AdlReservationReleased(address indexed market, address indexed user, uint256 insurance, uint256 reserve);

    function deposit(uint256 usdc) external;
    function withdraw(uint256 usdc) external;
    function freeBalance(address user) external view returns (uint256);
    /// @notice Negative collateral is isolated position debt, never withdrawable free balance.
    function locked(address user, address market) external view returns (int256);
    function ledger(address market) external view returns (T.Ledger memory);
    function registrarOf(address market) external view returns (address);
    function creatorOf(address market) external view returns (address);
    function governor() external view returns (address);
    function guardian() external view returns (address);
    function fundInsurance(address market, uint256 amount) external;
    function lock(address user, uint256 amount) external;
    function release(address user, uint256 amount) external;
    function settlePnl(address user, int256 pnl) external;
    function settleFunding(address user, int256 owed) external;
    function chargeFee(address user, T.FeeBreakdown calldata fee, bool fromLocked) external;
    function sweepFunding(uint256 amount) external;
    function coverDebt(address user) external returns (uint256);
    function backstopBalance() external view returns (uint256);
    function fundBackstop(uint256 amount) external;
    function moveInsuranceToBackstop(address market, uint256 amount) external;
    function coverBadDebt(address user) external returns (uint256 insurance, uint256 backstop, uint256 remaining);
    function liveCoverage(address market) external view returns (uint256 insurance, uint256 backstop);
    function adlReservation(address market, address user) external view returns (T.AdlReservation memory);
    function adlReserved(address market, address user) external view returns (uint256);
    function adlReservedTotal(address market) external view returns (uint256);
    function reserveAdl(address user, uint256 roundingTarget)
        external
        returns (uint256 coverage, uint256 roundingFromCoverage, uint256 roundingFromReserve);
    function consumeAdlCoverage(address user, uint256 amount) external;
    function restoreAdlCoverage(address user, uint256 amount) external;
    function returnAdlCoverage(address user, uint256 amount) external;
    function payAdlRounding(address user, address winner) external returns (bool paid);
    function releaseAdlReservation(address user) external returns (uint256 returned);
    function coverLiquidationLoss(address user, uint256 amount)
        external
        returns (uint256 insurance, uint256 backstop, uint256 remaining);
    function chargeLiquidationPenalty(address user, address liquidator, uint256 nominal) external returns (uint256);
    function transferAdlProfit(address donor, address debtor, uint256 amount) external;
    function claimCreatorFees() external returns (uint256);
    function transferCreator(address to) external;
    function claimProtocolFees(address market) external returns (uint256);
    function protocolReserve() external view returns (uint256);
    function reserveFloor() external view returns (uint256);
    function totalDeficit() external view returns (uint256);
    function deficit(address market) external view returns (uint256);
    function admitMarket(uint256 oiCap, uint64 fundingCapPerBlock) external;
    function requireOpenAllowed(address market) external view;
    function fundProtocolReserve(uint256 usdc) external;
    function recapitalize(address market, uint256 usdc) external;
    function contributeToDeficit(address market, uint256 amount) external;
    function allocateProtocolFees(address market, uint256 maxEntries)
        external
        returns (uint256 repaid, uint256 reserved);
    /// @notice Trusted market calls once after closing its whole book and applying losses/profit haircuts.
    function finalizeSettlement(address[] calldata debtors) external returns (uint256 uncovered);
    function setOperator(address op, T.OperatorPolicy calldata policy) external;
    function revokeOperator(address op) external;
    function checkAndConsume(address user, address op, uint256 notional, bool isClose, bytes32[] calldata marketProof)
        external;
    function registerReferralCode(bytes32 code) external;
    function setReferrer(bytes32 code) external;
    function referrerOf(address user) external view returns (address);
    function claimReferral() external;
}
