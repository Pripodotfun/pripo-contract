// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IPriceSource {
    /// @return price Quote per base, WAD.
    /// @return updatedBlock Block at which the price was valid.
    /// @return confBps Half-width of the confidence interval, in basis points.
    /// @return isExternal False for oracle-less markets.
    function getPrice(bytes32 feedId, bytes calldata update)
        external
        payable
        returns (uint256 price, uint64 updatedBlock, uint16 confBps, bool isExternal);
    function isSupported(bytes32 feedId) external view returns (bool);
}
