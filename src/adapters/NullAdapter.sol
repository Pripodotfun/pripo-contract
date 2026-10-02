// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPriceSource} from "../interfaces/IPriceSource.sol";
import {IPripoErrors as E} from "../interfaces/IPripoErrors.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Canonical oracle-less source. The zero feed uses the market's mark TWAP and skew funding.
// The payable signature implements IPriceSource; every nonzero msg.value is explicitly rejected and tested.
// slither-disable-next-line locked-ether
contract NullAdapter is IPriceSource {
    function getPrice(bytes32 feedId, bytes calldata update) external payable returns (uint256, uint64, uint16, bool) {
        if (msg.value != 0) revert E.UnexpectedValue();
        if (feedId != bytes32(0) || update.length != 0) revert E.InvalidOracle();
        return (0, SafeCast.toUint64(block.number), 0, false);
    }

    function isSupported(bytes32 feedId) external pure returns (bool) {
        return feedId == bytes32(0);
    }
}
