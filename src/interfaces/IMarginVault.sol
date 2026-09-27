// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {PripoTypes as T} from "../types/PripoTypes.sol";
import {IPripoErrors} from "./IPripoErrors.sol";

/// @notice Spec vault surface. Deposit/withdraw use raw USDC; internal accounting uses WAD.
interface IMarginVault is IPripoErrors {
    event OperatorSet(address indexed user, address indexed operator, uint64 expiry, uint128 maxTotalNotional);
    function deposit(uint256 usdc) external;
    function withdraw(uint256 usdc) external;
    function lock(address user, uint256 amt) external;
    function release(address user, uint256 amt) external;
    function settle(address user, int256 delta) external;
    function setOperator(address op, T.OperatorPolicy calldata policy) external;
    function revokeOperator(address op) external;
    function checkAndConsume(address user, address op, address market, uint256 notional) external;
    function registerReferralCode(bytes32 code) external;
    function setReferrer(bytes32 code) external;
    function referrerOf(address user) external view returns (address);
    function accrueReferral(address referrer, uint256 amt) external;
    function claimReferral() external;
    // Reserved Phase 2 surface; no implementation or Phase 1 behavior is implied.
    function enableCrossMargin(bool on) external;
    function accountHealth(address user) external view returns (int256);
}
