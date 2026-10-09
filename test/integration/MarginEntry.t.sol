// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPripoErrors as E} from "../../src/interfaces/IPripoErrors.sol";
import {CurveMath as Curve} from "../../src/libraries/CurveMath.sol";
import {FundingMath} from "../../src/libraries/FundingMath.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {MarketFixture} from "../helpers/MarketFixture.sol";

contract MarginEntryTest is MarketFixture {
    function _assertFunding() internal view {
        FundingMath.surplus(
            market.fundingState(), vault.ledger(address(market)).fundingPool, market.longSize(), market.shortSize()
        );
    }

    function setUp() public {
        _setup(false);
    }

    function testFuzz_MarginEntryMatchesQuoteAndCash(bool isLong, uint96 marginSeed, bool twoX) public {
        uint256 margin = bound(uint256(marginSeed), 1e12, 500e18);
        uint16 leverage = twoX ? 2 : 1;
        uint256 beforeFree = vault.freeBalance(alice);
        T.MarginOpenQuote memory q;
        try market.quoteOpenWithMargin(alice, isLong, margin, leverage) returns (T.MarginOpenQuote memory quoted) {
            q = quoted;
        } catch (bytes memory revertData) {
            // The impact minimum can bind below the configured leverage ceiling, especially for shorts.
            assertEq(bytes4(revertData), E.InsufficientMargin.selector);
            vm.prank(alice);
            vm.expectRevert(revertData);
            market.openWithMargin(isLong, margin, leverage, isLong ? type(uint256).max : 0, "");
            assertEq(vault.freeBalance(alice), beforeFree);
            assertEq(market.position(alice).size, 0);
            _assertCash();
            return;
        }
        vm.prank(alice);
        T.MarginOpenResult memory result = market.openWithMargin(isLong, margin, leverage, q.avgFill, "");
        T.Position memory p = market.position(alice);
        assertEq(p.size, q.size);
        assertEq(p.margin, margin);
        assertEq(p.entryCost, q.notional);
        assertLe(p.entryCost, margin * leverage);
        assertLt(margin * leverage - p.entryCost, 1000, "bounded integer quote dust at fixture price");
        assertEq(beforeFree - vault.freeBalance(alice), margin + q.fee);
        assertEq(keccak256(abi.encode(result.quote)), keccak256(abi.encode(q)));
        (int256 health, bool liquidatable) = market.health(alice);
        assertEq(result.healthWad, health);
        assertEq(result.liquidatable, liquidatable);
        (uint256 liq, T.LiquidationReference ref, T.LiquidationPriceReason reason) = market.liquidationPriceInfo(alice);
        assertEq(result.liquidationPrice, liq);
        assertEq(uint8(result.referenceKind), uint8(ref));
        assertEq(uint8(result.reason), uint8(reason));
        _assertCash();
        _assertFunding();
    }

    function testSameSideAdditionBlendsAfterFunding() public {
        _open(alice, 1e18);
        _open(bob, -0.1e18);
        vm.roll(block.number + 100);
        T.Position memory beforePosition = market.position(alice);
        (,,, int256 funding) = market.quoteClose(alice, 1e18);
        T.MarginOpenQuote memory q = market.quoteOpenWithMargin(alice, true, 100e18, 1);
        vm.prank(alice);
        market.openWithMargin(true, 100e18, 1, q.avgFill, "");
        T.Position memory afterPosition = market.position(alice);
        assertEq(afterPosition.size, beforePosition.size + q.size);
        assertEq(afterPosition.entryCost, beforePosition.entryCost + q.notional);
        assertEq(afterPosition.margin, uint256(int256(beforePosition.margin) - funding) + 100e18);
        assertEq(q.positionMargin, afterPosition.margin);
        assertEq(q.positionEntry, afterPosition.entryCost);
        _close(alice, 1e18);
        _close(bob, 1e18);
        _assertCash();
        _assertFunding();
    }

    function testImpactCeilingCanBeBelowConfiguredLeverage() public {
        vm.expectPartialRevert(E.InsufficientMargin.selector);
        market.quoteOpenWithMargin(alice, false, 500e18, 2);
        T.MarginOpenQuote memory q = market.quoteOpenWithMargin(alice, false, 500e18, 1);
        vm.prank(alice);
        market.openWithMargin(false, 500e18, 1, q.avgFill, "");
        assertEq(market.position(alice).margin, 500e18);
        _assertCash();
    }

    function testRejectionsLeaveNoPartialLockOrFill() public {
        uint256 free = vault.freeBalance(alice);
        vm.startPrank(alice);
        vm.expectRevert(E.ZeroAmount.selector);
        market.openWithMargin(true, 0, 1, type(uint256).max, "");
        vm.expectRevert(abi.encodeWithSelector(E.InvalidLeverage.selector, 0));
        market.openWithMargin(true, 100e18, 0, type(uint256).max, "");
        vm.expectRevert(abi.encodeWithSelector(E.InvalidLeverage.selector, 3));
        market.openWithMargin(true, 100e18, 3, type(uint256).max, "");
        vm.expectPartialRevert(E.Slippage.selector);
        market.openWithMargin(true, 100e18, 1, 1, "");
        vm.expectPartialRevert(E.OICapExceeded.selector);
        market.openWithMargin(true, 2000e18, 2, type(uint256).max, "");
        vm.stopPrank();
        assertEq(vault.freeBalance(alice), free);
        assertEq(market.longSize(), 0);
        assertEq(market.position(alice).size, 0);
        _assertCash();
        _open(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(E.PositionExists.selector);
        market.openWithMargin(false, 100e18, 1, 0, "");
    }

    function testFeesAreAdditionalAndInsufficientBalanceRevertsAtomically() public {
        vm.startPrank(alice);
        vault.withdraw(9900e6);
        vm.expectPartialRevert(E.InsufficientMargin.selector);
        market.openWithMargin(true, 100e18, 1, type(uint256).max, "");
        vm.stopPrank();
        assertEq(vault.freeBalance(alice), 100e18);
        assertEq(market.position(alice).size, 0);
        _assertCash();
    }

    function testOwnerOnlyMarginCannotUseAnotherUsersPolicy() public {
        vm.prank(alice);
        vault.setOperator(carol, T.OperatorPolicy(uint64(block.number + 100), 2000e18, 5000e18, 0, 0, true));
        vm.prank(carol);
        market.openWithMargin(true, 100e18, 1, type(uint256).max, "");
        assertEq(market.position(alice).size, 0);
        assertEq(market.position(carol).margin, 100e18);
        (,,, uint128 used,,) = vault.operators(alice, carol);
        assertEq(used, 0);
        _assertCash();
    }

    function testPausedOpensCannotLockMargin() public {
        vm.prank(guardian);
        market.pauseOpens();
        vm.prank(alice);
        vm.expectRevert(E.MarketNotActive.selector);
        market.openWithMargin(true, 100e18, 1, type(uint256).max, "");
        assertEq(market.position(alice).size, 0);
        _assertCash();
    }

    function testFuzz_InverseCurveIsMaximal(bool isLong, uint96 priceSeed, uint96 budgetSeed) public pure {
        uint256 price = uint256(priceSeed) % 1e24 + 1e12;
        T.AmmState memory a = Curve.seed(price, 2_000_000e18);
        uint256 budget = uint256(budgetSeed) % 1000e18 + 1e12;
        int256 size = Curve.sizeForNotional(a, isLong, budget);
        T.Fill memory q = Curve.quote(a, size);
        assertLe(q.quoteAmount, budget);
        assertGt(Curve.quote(a, size + (isLong ? int256(1) : -int256(1))).quoteAmount, budget);
    }
}

contract ExternalMarginEntryTest is MarketFixture {
    function setUp() public {
        _setup(true);
    }

    function testOracleFeeAndReentryUseSameGuardAsLegacyOpen() public {
        source.setFee(1);
        vm.deal(alice, 1);
        source.setCallback(
            address(market), abi.encodeCall(market.openWithMargin, (true, 10e18, 1, type(uint256).max, bytes("")))
        );
        vm.prank(alice);
        T.MarginOpenResult memory result = market.openWithMargin{value: 1}(false, 50e18, 5, 0, "");
        assertFalse(source.callbackSucceeded());
        assertEq(market.position(alice).margin, 50e18);
        assertEq(result.quote.notional, market.position(alice).entryCost);
        assertEq(address(source).balance, 1);
        _assertCash();
    }
}
