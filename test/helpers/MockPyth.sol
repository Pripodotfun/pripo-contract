// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPythPriceFeed} from "../../src/interfaces/IPythPriceFeed.sol";

/// @dev ABI-compatible test provider. Update blobs are test encodings, not signed Pyth messages.
contract MockPyth is IPythPriceFeed {
    mapping(bytes32 => Price) private _prices;
    uint256 public updates;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSucceeded;
    bytes public callbackResult;

    error MissingPrice();
    error StalePrice();

    function set(bytes32 id, Price memory price) external {
        _prices[id] = price;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function getPriceUnsafe(bytes32 id) public view returns (Price memory price) {
        price = _prices[id];
        if (price.publishTime == 0) revert MissingPrice();
    }

    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (Price memory price) {
        price = getPriceUnsafe(id);
        if (block.timestamp > price.publishTime && block.timestamp - price.publishTime > age) revert StalePrice();
    }

    function getUpdateFee(bytes[] calldata data) external pure returns (uint256) {
        return data.length;
    }

    function updatePriceFeeds(bytes[] calldata data) external payable {
        require(msg.value == data.length, "wrong mock fee");
        ++updates;
        if (callbackTarget != address(0)) (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
        for (uint256 i; i < data.length; ++i) {
            (bytes32 id, Price memory price) = abi.decode(data[i], (bytes32, Price));
            if (price.publishTime > _prices[id].publishTime) _prices[id] = price;
        }
    }
}
