// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Permissionless demo collateral on Monad testnet; not issued or backed by Circle.
contract TestnetMockUSDC is ERC20 {
    constructor(address recipient) ERC20("Pripo Mock USDC", "mUSDC") {
        require(block.chainid == 10143, "testnet only");
        _mint(recipient, 100_000e6);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mint 10,000 demo tokens to the caller. No faucet quota or external service is required.
    function faucet() external {
        require(block.chainid == 10143, "testnet only");
        _mint(msg.sender, 10_000e6);
    }
}
