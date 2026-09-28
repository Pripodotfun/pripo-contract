// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PripoTypes as T} from "../types/PripoTypes.sol";
import {IPripoErrors} from "./IPripoErrors.sol";

/// @notice Implemented isolated trading runtime. Proof overloads use the vault's double-hashed market leaves.
interface IMarketCore is IPripoErrors {
    function externalIndex() external view returns (bool);
    event PositionOpened(
        address indexed market,
        address indexed user,
        address operator,
        int256 size,
        uint256 avgFill,
        uint256 margin,
        uint256 fee
    );
    event PositionClosed(
        address indexed market,
        address indexed user,
        address operator,
        int256 sizeClosed,
        uint256 avgFill,
        int256 pnl,
        int256 funding,
        uint256 fee
    );
    event MarginChanged(address indexed market, address indexed user, int256 delta);
    event FundingAccrued(
        address indexed market, int256 ratePerBlock, int256 longIndex, int256 shortIndex, uint64 blockNumber
    );
    event FundingSurplusSwept(address indexed market, uint256 amount);
    event StatusChanged(address indexed market, uint8 from, uint8 to, uint64 blockNumber);
    event BadDebt(address indexed market, address indexed user, uint256 amount, uint8 coveredBy);
    event FeesAccrued(address indexed market, uint256 protocol, uint256 creator, uint256 insurance);
    event CreatorFeesClaimed(address indexed market, address indexed creator, uint256 amount);
    event CreatorTransferred(address indexed previousCreator, address indexed newCreator);

    function open(int256 size, uint256 limitPrice, bytes calldata oracleUpdate) external payable;
    function openFor(address user, int256 size, uint256 limitPrice, bytes calldata oracleUpdate) external payable;
    function openFor(
        address user,
        int256 size,
        uint256 limitPrice,
        bytes calldata oracleUpdate,
        bytes32[] calldata proof
    ) external payable;
    function close(uint256 sizeFraction, uint256 limitPrice, bytes calldata oracleUpdate) external payable;
    function closeFor(address user, uint256 sizeFraction, uint256 limitPrice, bytes calldata oracleUpdate)
        external
        payable;
    function closeFor(
        address user,
        uint256 sizeFraction,
        uint256 limitPrice,
        bytes calldata oracleUpdate,
        bytes32[] calldata proof
    ) external payable;
    function addMargin(uint256 amount) external;
    function removeMargin(uint256 amount) external;
    function poke() external;
    function sweepFundingSurplus() external;
    function quoteOpen(int256 size)
        external
        view
        returns (uint256 avgFill, uint256 fee, uint256 marginRequired, uint256 newMark);
    function quoteOpenFor(address user, int256 size)
        external
        view
        returns (uint256 avgFill, uint256 fee, uint256 marginRequired, uint256 newMark);
    function quoteClose(address user, uint256 sizeFraction)
        external
        view
        returns (uint256 avgFill, uint256 fee, int256 pnl, int256 fundingOwed);
    function health(address user) external view returns (int256 healthWad, bool liquidatable);
    function realizablePnl(address user) external view returns (int256 atCurrentReserves, int256 atTwapReserves);
    function curveAccounts() external view returns (uint256 curveBase, int256 entryCostNet, int256 clearing);
    function markPrice() external view returns (uint256);
    function indexPrice() external view returns (uint256 price, uint64 updatedBlock, bool isExternal);
    function fundingRatePerBlock() external view returns (int256);
    function openInterest() external view returns (uint256 longNotional, uint256 shortNotional, uint256 oiCap);
    function position(address user) external view returns (T.Position memory);
    function positionDebt(address user) external view returns (uint256);
    function config() external view returns (T.MarketConfig memory);
    function status() external view returns (uint8, uint64 since);
    function remark() external;
    function remark(bytes calldata update) external payable;
    function claimCreatorFees() external;
    function transferCreator(address to) external;
    function reseed(uint256 newDepth) external;
    function pauseOpens() external;
    function resumeOpens() external;
}
