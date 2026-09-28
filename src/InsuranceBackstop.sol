// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IInsuranceBackstop} from "./interfaces/IInsuranceBackstop.sol";
import {IMarginVault} from "./interfaces/IMarginVault.sol";
import {IMarketCore} from "./interfaces/IMarketCore.sol";
import {IPripoErrors as E} from "./interfaces/IPripoErrors.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Backstop policy and per-market claim budgets. All collateral remains in MarginVault.
contract InsuranceBackstop is IInsuranceBackstop, ReentrancyGuard {
    uint256 public constant WINDOW_BLOCKS = 288_000;
    address public immutable vault;

    struct Window {
        uint64 startBlock;
        bool initialized;
        uint256 limit;
        uint256 used;
    }
    mapping(address => Window) public windows;

    event BackstopClaimed(address indexed market, uint256 amount, uint256 used, uint256 limit, uint64 startBlock);
    event InsuranceSwept(address indexed market, uint256 amount);

    constructor(address vault_) {
        if (vault_.code.length == 0) revert E.InvalidAddress();
        vault = vault_;
    }

    /// @dev Window budget snapshots the available backstop on the first claim, and never refills within that window.
    function consume(address market, uint256 requested) external nonReentrant returns (uint256 amount) {
        if (msg.sender != vault) revert E.Unauthorized();
        _checkMarket(market);
        Window storage w = windows[market];
        uint256 balance = IMarginVault(vault).backstopBalance();
        if (!w.initialized || block.number >= uint256(w.startBlock) + WINDOW_BLOCKS) {
            w.startBlock = SafeCast.toUint64(block.number);
            w.initialized = true;
            w.limit = _budget(market, balance);
            w.used = 0;
        }
        amount = Math.min(requested, Math.min(balance, w.limit - w.used));
        w.used += amount;
        emit BackstopClaimed(market, amount, w.used, w.limit, w.startBlock);
    }

    function capacity(address market) external view returns (uint256) {
        _checkMarket(market);
        Window memory w = windows[market];
        uint256 balance = IMarginVault(vault).backstopBalance();
        if (!w.initialized || block.number >= uint256(w.startBlock) + WINDOW_BLOCKS) {
            return _budget(market, balance);
        }
        return Math.min(balance, w.limit - w.used);
    }

    function topUp(address market) external nonReentrant returns (uint256 amount) {
        _checkMarket(market);
        // The reserve depends on the cap, not current long/short open interest.
        // slither-disable-next-line unused-return
        (,, uint256 oiCap) = IMarketCore(market).openInterest();
        uint256 multiplier = IMarketCore(market).externalIndex() ? 20 : 10;
        uint256 retained = Math.mulDiv(oiCap, 2, multiplier, Math.Rounding.Ceil);
        uint256 insurance = IMarginVault(vault).ledger(market).insurance;
        if (insurance > retained) amount = insurance - retained;
        if (amount != 0) IMarginVault(vault).moveInsuranceToBackstop(market, amount);
        emit InsuranceSwept(market, amount);
    }

    function _budget(address market, uint256 balance) private view returns (uint256) {
        return Math.mulDiv(balance, IMarketCore(market).externalIndex() ? 2000 : 1000, 10_000);
    }

    function _checkMarket(address market) private view {
        if (IMarginVault(vault).registrarOf(market) == address(0)) revert E.Unauthorized();
    }
}
