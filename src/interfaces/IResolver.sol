// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {IPripoErrors} from "./IPripoErrors.sol";

interface IResolver is IPripoErrors {
    event SettlementProposed(address indexed market, address indexed proposer, uint256 price, uint64 windowEnd);
    event SettlementDisputed(address indexed market, address indexed disputer, uint256 counterPrice);
    function propose(address market, uint256 price, string calldata evidenceURI) external;
    function dispute(address market, uint256 counterPrice) external;
    function finalize(address market) external;
    function councilResolve(address market, uint256 price) external;
    function startStaleWindDown(address market) external;
    function state(address market) external view returns (uint8);
}
