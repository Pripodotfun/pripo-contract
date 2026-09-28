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
    function claimCreatorFees() external returns (uint256);
    function transferCreator(address to) external;
    function claimProtocolFees(address market) external returns (uint256);
    function setOperator(address op, T.OperatorPolicy calldata policy) external;
    function revokeOperator(address op) external;
    function checkAndConsume(address user, address op, uint256 notional, bool isClose, bytes32[] calldata marketProof)
        external;
    function registerReferralCode(bytes32 code) external;
    function setReferrer(bytes32 code) external;
    function referrerOf(address user) external view returns (address);
    function claimReferral() external;
}
