// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IInsuranceBackstop {
    function vault() external view returns (address);
    function consume(address market, uint256 requested) external returns (uint256);
    function capacity(address market) external view returns (uint256);
    function topUp(address market) external returns (uint256);
}
