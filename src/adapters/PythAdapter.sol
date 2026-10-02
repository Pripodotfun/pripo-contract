// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPriceSource} from "../interfaces/IPriceSource.sol";
import {IPripoErrors as E} from "../interfaces/IPripoErrors.sol";
import {IPythPriceFeed} from "../interfaces/IPythPriceFeed.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Pyth Core pull updates, WAD prices and conservative timestamp-to-block age estimates.
contract PythAdapter is IPriceSource, ReentrancyGuard {
    IPythPriceFeed public immutable pyth;
    uint32 public immutable maxUpdateAgeSeconds;
    uint32 public immutable blockTimeMillis;

    /// @param blockTimeMillis_ Deployment estimate; the protocol's launch configuration uses 300 ms.
    constructor(IPythPriceFeed pyth_, uint32 maxUpdateAgeSeconds_, uint32 blockTimeMillis_) {
        if (address(pyth_).code.length == 0) revert E.InvalidAddress();
        if (maxUpdateAgeSeconds_ == 0 || blockTimeMillis_ == 0) revert E.InvalidConfiguration();
        pyth = pyth_;
        maxUpdateAgeSeconds = maxUpdateAgeSeconds_;
        blockTimeMillis = blockTimeMillis_;
    }

    /// @param update Empty for a cached read; otherwise abi.encode(bytes[] signedPythUpdates).
    /// @dev Exact fees are forwarded. Empty reads preserve age and never make stale data fresh.
    function getPrice(bytes32 feedId, bytes calldata update)
        external
        payable
        nonReentrant
        returns (uint256 price, uint64 updatedBlock, uint16 confBps, bool isExternal)
    {
        IPythPriceFeed.Price memory observation;
        if (update.length == 0) {
            if (msg.value != 0) revert E.UnexpectedValue();
            observation = pyth.getPriceUnsafe(feedId);
        } else {
            bytes[] memory payload = abi.decode(update, (bytes[]));
            if (payload.length == 0) revert E.InvalidOracle();
            if (msg.value != pyth.getUpdateFee(payload)) revert E.UnexpectedValue();
            pyth.updatePriceFeeds{value: msg.value}(payload);
            observation = pyth.getPriceNoOlderThan(feedId, maxUpdateAgeSeconds);
        }
        if (observation.price <= 0 || observation.publishTime == 0 || observation.publishTime > block.timestamp) {
            revert E.InvalidOracle();
        }
        // These are all exponents that can produce a nonzero WAD price <= the market's 1e28 limit.
        if (observation.expo < -36 || observation.expo > 10) revert E.InvalidOracle();
        uint256 raw = uint256(uint64(observation.price));
        int256 shift = int256(observation.expo) + 18;
        price = shift >= 0 ? raw * 10 ** SafeCast.toUint256(shift) : raw / 10 ** SafeCast.toUint256(-shift);
        if (price == 0 || price > 1e28) revert E.InvalidOracle();
        uint256 confidence = Math.mulDiv(observation.conf, 10_000, raw, Math.Rounding.Ceil);
        confBps = SafeCast.toUint16(Math.min(confidence, type(uint16).max));
        uint256 age = Math.mulDiv(block.timestamp - observation.publishTime, 1000, blockTimeMillis, Math.Rounding.Ceil);
        // Saturating to block zero could falsely freshen ancient data on a young chain.
        if (age > block.number) revert E.InvalidOracle();
        updatedBlock = SafeCast.toUint64(block.number - age);
        return (price, updatedBlock, confBps, true);
    }

    function isSupported(bytes32 feedId) external view returns (bool) {
        try pyth.getPriceUnsafe(feedId) returns (IPythPriceFeed.Price memory observation) {
            return observation.publishTime != 0;
        } catch {
            return false;
        }
    }

    function updateFee(bytes calldata update) external view returns (uint256) {
        if (update.length == 0) return 0;
        bytes[] memory payload = abi.decode(update, (bytes[]));
        if (payload.length == 0) revert E.InvalidOracle();
        return pyth.getUpdateFee(payload);
    }
}
