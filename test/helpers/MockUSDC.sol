// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Test USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract HookUSDC is MockUSDC {
    address public hookTarget;
    bytes public hookData;
    bool public hookSucceeded;
    bool private _inHook;
    bool public tax;
    bool public hookOnReceive;
    bytes public hookResult;

    function configureIncomingHook(bool enabled) external {
        hookOnReceive = enabled;
    }

    function configure(address target, bytes calldata data, bool tax_) external {
        hookTarget = target;
        hookData = data;
        tax = tax_;
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (tax && from != address(0) && to != address(0) && amount > 0) super._update(to, address(0), 1);
        if ((from == hookTarget || (hookOnReceive && to == hookTarget)) && !_inHook) {
            _inHook = true;
            (hookSucceeded, hookResult) = hookTarget.call(hookData);
            _inHook = false;
        }
    }
}
