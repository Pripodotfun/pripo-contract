// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {PripoTypes as T} from "../types/PripoTypes.sol";
import {IPripoErrors} from "./IPripoErrors.sol";

interface IMarketFactory is IPripoErrors {
    event MarketCreated(
        address indexed market, address indexed creator, string symbol, bool isExternal, uint256 depth, uint256 seedBond
    );
    function createMarket(T.CreateParams calldata p) external returns (address market);
    function predictAddress(string calldata symbol) external view returns (address);
    function markets(uint256 i) external view returns (address);
    function marketCount() external view returns (uint256);
    function isMarket(address market) external view returns (bool);
    function listFeed(address adapter, bytes32 feedId) external;
}
