// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarketCore} from "./IMarketCore.sol";

/// @notice Planned complete Phase 1 interface. Market currently implements IMarketCore.
interface IMarket is IMarketCore {
    event AutoDeleveraged(address indexed market, address indexed user, int256 sizeClosed, uint256 price);
    event MarketSettled(address indexed market, uint256 price, uint16 haircutBps);

    function liquidationPrice(address user) external view returns (uint256);
    function maxOpenable(address user, bool isLong) external view returns (int256 size);
    function declareSettlementEvent(uint8 kind, uint64 expectedBlock) external;
    function windDown() external;
}
