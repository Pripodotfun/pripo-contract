// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Market} from "../../src/Market.sol";
import {MarketFundingCapacity as Capacity} from "../../src/market/MarketFundingCapacity.sol";
import {MarketState as S} from "../../src/market/MarketState.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {MonadMarketPythFixture} from "./MonadMarketPyth.t.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Explicit historical-debt injection only. Both vault moves balance; production has no such entry point.
contract ForkDebtMarket is Market {
    function seedPairedDebt(address payer, address receiver, uint256 amount) external {
        S.Data storage s = S.load();
        s.vault.settleFunding(payer, int256(amount));
        s.vault.settleFunding(receiver, -int256(amount));
        Capacity.refresh(s, payer);
        Capacity.refresh(s, receiver);
    }
}

abstract contract MonadPythGasFixture is MonadMarketPythFixture {
    uint256 internal unit;

    function setUp() public virtual override {
        super.setUp();
        // Preserve the $100-unit geometry of the local gas fixtures at the real BTC observation.
        (uint256 price,,,) = adapter.getPrice(feed, "");
        unit = Math.mulDiv(100e18, 1e18, price);
    }

    function _marketImplementation() internal override returns (address) {
        return address(new ForkDebtMarket());
    }

    function _fundAndOpen(address user, int256 size) internal {
        deal(address(usdc), user, 300e6);
        vm.startPrank(user);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(300e6);
        market.open(size, size > 0 ? type(uint256).max : 0, "");
        vm.stopPrank();
    }

    function _debtTo(address receiver, int256 targetCollateral) internal {
        uint256 amount = uint256(vault.locked(address(this), address(market)) - targetCollateral);
        ForkDebtMarket(address(market)).seedPairedDebt(address(this), receiver, amount);
    }

    function _assertCash(uint160 first, uint256 count) internal view {
        T.Ledger memory l = vault.ledger(address(market));
        int256 cash = int256(
                vault.protocolReserve() + vault.backstopBalance() + vault.adlReservedTotal(address(market))
            ) + int256(l.insurance + l.creatorOwed + l.protocolOwed + l.skewPool) + l.clearing + l.fundingPool
            - int256(vault.deficit(address(market))) + int256(vault.freeBalance(address(this)) + vault.freeBalance(bob))
            + vault.locked(address(this), address(market)) + vault.locked(bob, address(market));
        for (uint256 i; i < count; ++i) {
            address user = address(uint160(uint256(first) + i));
            cash += int256(vault.freeBalance(user)) + vault.locked(user, address(market));
        }
        assertEq(cash, int256(usdc.balanceOf(address(vault)) * 1e12));
    }
}

contract MonadTerminalGasTest is MonadPythGasFixture {
    function setUp() public override {
        super.setUp();
        market.open(int256(10 * unit), type(uint256).max, "");
        for (uint256 i; i < 127; ++i) {
            _fundAndOpen(address(uint160(0x10000 + i)), i % 2 == 0 ? -int256(unit / 10) : int256(unit / 10));
        }
        _debtTo(address(0x10000), -int256(vault.ledger(address(market)).insurance) - 100e18);
    }

    function testWholeBookTerminalSettlementWithRealSignedUpdate() public {
        assertEq(market.positionCount(), 128);
        uint256 gasBefore = gasleft();
        market.liquidate{value: fee}(address(this), abi.encode(updates));
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("128-position terminal liquidation with real Pyth update gross gas", used);
        assertLt(used, 20_000_000);
        (uint8 status,) = market.status();
        assertEq(status, uint8(T.Status.Settled));
        assertEq(market.positionCount(), 0);
        assertEq(market.longSize() + market.shortSize(), 0);
        assertEq(vault.ledger(address(market)).clearing, 0);
        assertEq(vault.ledger(address(market)).fundingPool, 0);
        assertEq(vault.deficit(address(market)), 0);
        _assertCash(0x10000, 127);
    }
}

contract MonadAdlGasTest is MonadPythGasFixture {
    function setUp() public override {
        super.setUp();
        market.open(int256(10 * unit), type(uint256).max, "");
        vm.prank(bob);
        market.open(int256(10 * unit), type(uint256).max, "");
        for (uint256 i; i < 126; ++i) {
            address user = address(uint160(0x20000 + i));
            _fundAndOpen(user, -int256(unit * 8 / 100));
            vm.prank(user);
            market.addMargin((126 - i) * 2e18);
        }
        vm.prank(bob);
        market.close(0.999e18, 0, "");
        _debtTo(bob, -int256(vault.ledger(address(market)).insurance) + 0.5e18);
    }

    function testRankedAdlAndFallbackWithRealSignedUpdate() public {
        assertEq(market.positionCount(), 128);
        uint256 gasBefore = gasleft();
        market.liquidate{value: fee}(address(this), abi.encode(updates));
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("128-position first 64 ADL matches with real Pyth update gross gas", used);
        assertLt(used, 20_000_000);
        T.AdlPending memory pending = market.pendingAdl(address(this));
        assertTrue(pending.active);
        assertEq(pending.chunksMatched, 64);
        vm.roll(block.number + market.config().adlPendingWindow);
        vm.warp(block.timestamp + 300);
        gasBefore = gasleft();
        market.completeAdl(address(this), 64);
        used = gasBefore - gasleft();
        emit log_named_uint("remaining fallback matches on Monad fork gross gas", used);
        assertLt(used, 20_000_000);
        assertFalse(market.pendingAdl(address(this)).active);
        assertEq(market.pendingAdlCount(), 0);
        assertEq(market.position(address(this)).size, 0);
        assertEq(vault.deficit(address(market)), 0);
        assertEq(market.positionCount(), 2);
        _assertCash(0x20000, 126);
    }
}
