// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Minimal Pyth Core EVM ABI consumed by the adapter.
/// @dev Shapes follow https://api-reference.pyth.network/price-feeds/evm . No oracle verification is reimplemented.
interface IPythPriceFeed {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    function getPriceUnsafe(bytes32 id) external view returns (Price memory);
    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (Price memory);
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256);
    function updatePriceFeeds(bytes[] calldata updateData) external payable;
}
