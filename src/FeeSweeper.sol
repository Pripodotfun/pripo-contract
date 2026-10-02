// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarginVault} from "./interfaces/IMarginVault.sol";
import {IPripoErrors as E} from "./interfaces/IPripoErrors.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Permissionless bounded allocation. All cash stays in the vault until its gated treasury claim.
contract FeeSweeper is ReentrancyGuard {
    uint256 public constant MAX_MARKETS = 32;
    uint256 public constant MAX_DEFICITS_PER_MARKET = 32;
    IMarginVault public immutable vault;

    event FeesSwept(
        address indexed caller, uint256 markets, uint256 repaid, uint256 reserved, uint256 paid, bool treasuryReady
    );
    event FeesAllocated(address indexed caller, uint256 markets, uint256 repaid, uint256 reserved);

    constructor(IMarginVault vault_) {
        if (address(vault_).code.length == 0) revert E.InvalidAddress();
        vault = vault_;
    }

    /// @notice Keep partial repayment/refill even when the treasury gate cannot yet be satisfied.
    // At most 32 calls to the fixed vault; its claim holds the vault guard and sends only to its stored treasury.
    // slither-disable-next-line calls-loop
    function sweep(address[] calldata markets)
        external
        nonReentrant
        returns (uint256 repaid, uint256 reserved, uint256 paid)
    {
        _validate(markets);
        (repaid, reserved) = _allocate(markets, MAX_DEFICITS_PER_MARKET);
        bool ready = vault.totalDeficit() == 0 && vault.protocolReserve() >= vault.reserveFloor();
        if (ready) {
            for (uint256 i; i < markets.length; ++i) {
                paid += vault.claimProtocolFees(markets[i]);
            }
        }
        emit FeesSwept(msg.sender, markets.length, repaid, reserved, paid, ready);
    }

    /// @notice Allocate without making token transfers, with a caller-selected per-market queue budget.
    function allocate(address[] calldata markets, uint256 maxEntries)
        external
        nonReentrant
        returns (uint256 repaid, uint256 reserved)
    {
        if (maxEntries == 0 || maxEntries > MAX_DEFICITS_PER_MARKET) revert E.AllocationLimit();
        _validate(markets);
        (repaid, reserved) = _allocate(markets, maxEntries);
        emit FeesAllocated(msg.sender, markets.length, repaid, reserved);
    }

    // At most 32 markets and 32 queue entries per market; only the fixed vault is called.
    // slither-disable-next-line calls-loop
    function _allocate(address[] calldata markets, uint256 maxEntries)
        private
        returns (uint256 repaid, uint256 reserved)
    {
        for (uint256 i; i < markets.length; ++i) {
            (uint256 debt, uint256 reserve) = vault.allocateProtocolFees(markets[i], maxEntries);
            repaid += debt;
            reserved += reserve;
        }
    }

    // At most 32 static registry reads of the fixed vault, before any allocation.
    // slither-disable-next-line calls-loop
    function _validate(address[] calldata markets) private view {
        if (markets.length == 0 || markets.length > MAX_MARKETS) revert E.AllocationLimit();
        for (uint256 i; i < markets.length; ++i) {
            if (vault.registrarOf(markets[i]) == address(0)) revert E.Unauthorized();
            for (uint256 j; j < i; ++j) {
                if (markets[i] == markets[j]) revert E.InvalidConfiguration();
            }
        }
    }
}
