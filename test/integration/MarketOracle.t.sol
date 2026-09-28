// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Market} from "../../src/Market.sol";
import {IMarginVault} from "../../src/interfaces/IMarginVault.sol";
import {IPripoErrors as E} from "../../src/interfaces/IPripoErrors.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {MarketFixture} from "../helpers/MarketFixture.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract MarketOracleTest is MarketFixture {
    function setUp() public {
        _setup(true);
    }

    function testStaleAndHighConfidenceOpensRevertButCloseNeverReadsOracle() public {
        _open(alice, 10e18);
        uint256 calls = source.calls();
        source.setBroken(true);
        _close(alice, 0.5e18);
        assertEq(source.calls(), calls);
        source.setBroken(false);
        source.set(100e18, uint64(block.number), 101);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(E.OracleConfidence.selector, uint16(101)));
        market.open(1e18, type(uint256).max, "");
        source.set(100e18, uint64(block.number), 0);
        vm.roll(block.number + 11);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(E.StaleOracle.selector, uint64(11)));
        market.open(1e18, type(uint256).max, "");
        _close(alice, 1e18);
        _assertCash();
    }

    function testDegradeStopsFundingAndFreshRemarkRestoresTrading() public {
        _open(alice, 10e18);
        _open(bob, -1e18);
        vm.roll(block.number + 101);
        market.poke();
        (uint8 status,) = market.status();
        assertEq(status, uint8(T.Status.Degraded));
        assertEq(market.fundingRatePerBlock(), 0);
        int256 index = market.fundingState().longIndex;
        vm.roll(block.number + 10_000);
        market.poke();
        assertEq(market.fundingState().longIndex, index);
        vm.prank(carol);
        vm.expectRevert(E.MarketNotActive.selector);
        market.open(1e18, type(uint256).max, "");
        _close(bob, 1e18);
        source.set(100e18, uint64(block.number), 0);
        market.remark();
        (status,) = market.status();
        assertEq(status, uint8(T.Status.Active));
        _open(carol, -1e18);
        _assertCash();
    }

    function testSecondaryFallbackAndOracleFeeForwarding() public {
        Market withSecondary = Market(Clones.clone(address(new Market())));
        vault.registerMarket(address(withSecondary), creator);
        vm.prank(creator);
        vault.fundInsurance(address(withSecondary), 5_000e18);
        T.MarketConfig memory c = _config(true);
        c.secondarySource = address(secondary);
        withSecondary.initialize(IMarginVault(address(vault)), bytes32("TEST"), true, c, 100e18, 2_000_000e18);
        source.setBroken(true);
        vm.prank(alice);
        withSecondary.open(1e18, type(uint256).max, "");
        assertGt(secondary.calls(), 0);
        source.setBroken(false);
        source.setFee(123);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        market.open{value: 123}(1e18, type(uint256).max, "update");
        assertEq(address(source).balance, 123);
        assertEq(address(market).balance, 0);
        vm.prank(alice);
        vm.expectRevert(E.UnexpectedValue.selector);
        market.close{value: 1}(1e18, 0, "ignored");
    }

    function testNewOracleCannotRetroactivelyChangeFunding() public {
        _open(alice, 10e18);
        _open(bob, -1e18);
        vm.roll(block.number + 8);
        T.FundingState memory expected = market.fundingState();
        source.set(90e18, uint64(block.number), 0);
        market.remark();
        T.FundingState memory actual = market.fundingState();
        assertEq(actual.longIndex, expected.longIndex);
        assertEq(actual.shortIndex, expected.shortIndex);
        (, bool liquidatable) = market.health(alice);
        assertFalse(liquidatable);
        source.set(50e18, uint64(block.number), 0);
        market.remark();
        (, liquidatable) = market.health(alice);
        assertTrue(liquidatable);
    }

    function testSameBlockTradesDoNotMoveTwapHealthReference() public {
        vm.roll(block.number + 300);
        source.set(100e18, uint64(block.number), 0);
        market.remark();
        uint256 referencePrice = market.twapPrice();
        _open(alice, 10e18);
        _open(bob, 10e18);
        assertEq(market.twapPrice(), referencePrice);
        vm.roll(block.number + 150);
        assertGt(market.twapPrice(), referencePrice);
        assertLt(market.twapPrice(), market.markPrice());
        vm.roll(block.number + 600);
        assertEq(market.twapPrice(), market.markPrice());
    }

    function testOracleCallbackCannotReenterTradingOrInitialization() public {
        source.setCallback(address(market), abi.encodeCall(Market.poke, ()));
        _open(alice, 1e18);
        assertFalse(source.callbackSucceeded());
        assertEq(source.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        Market clone = Market(Clones.clone(address(new Market())));
        vault.registerMarket(address(clone), creator);
        vm.prank(creator);
        vault.fundInsurance(address(clone), 5_000e18);
        source.setCallback(address(clone), abi.encodeCall(Market.poke, ()));
        clone.initialize(IMarginVault(address(vault)), 0, true, _config(true), 100e18, 2_000_000e18);
        assertFalse(source.callbackSucceeded());
        assertEq(source.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
    }

    function testFreshSourcePreventsDegradationFromExpiredCache() public {
        vm.roll(block.number + 101);
        source.set(100e18, uint64(block.number), 0);
        _open(alice, 1e18);
        (uint8 status,) = market.status();
        assertEq(status, uint8(T.Status.Active));
        vm.roll(block.number + 101);
        source.set(100e18, uint64(block.number), 0);
        market.poke();
        (status,) = market.status();
        assertEq(status, uint8(T.Status.Active));
    }
}
