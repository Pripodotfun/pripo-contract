// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PripoTypes as T} from "../../src/types/PripoTypes.sol";

/// @dev Custody tests only: models the trusted engine's terminal boundary, not price/position settlement.
contract TerminalMarketStub {
    T.Status private _status;
    uint256 public longSize;
    uint256 public shortSize;

    function setState(T.Status state, uint256 longs, uint256 shorts) external {
        _status = state;
        longSize = longs;
        shortSize = shorts;
    }

    function status() external view returns (uint8, uint64) {
        return (uint8(_status), 0);
    }

    function externalIndex() external pure returns (bool) {
        return false;
    }

    function openInterest() external pure returns (uint256, uint256, uint256) {
        return (0, 0, 25_000e18);
    }
}
