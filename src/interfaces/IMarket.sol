// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarketCore} from "./IMarketCore.sol";

/// @notice Planned complete Phase 1 interface. Market currently implements IMarketCore.
interface IMarket is IMarketCore {
    function declareSettlementEvent(uint8 kind, uint64 expectedBlock) external;
    function windDown() external;
}
