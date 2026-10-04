// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Market} from "../../src/Market.sol";
import {IPripoErrors as E} from "../../src/interfaces/IPripoErrors.sol";
import {CurveMath as Curve} from "../../src/libraries/CurveMath.sol";
import {FundingMath as Funding} from "../../src/libraries/FundingMath.sol";
import {MarketAccounting as Engine} from "../../src/market/MarketAccounting.sol";
import {MarketSettlement as Settlement} from "../../src/market/MarketSettlement.sol";
import {MarketState as S} from "../../src/market/MarketState.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {DebtShockFixture} from "../helpers/DebtShockFixture.sol";
import {MarketFixture} from "../helpers/MarketFixture.sol";

contract MarketSettlementTest is DebtShockFixture {
    function setUp() public {
        _setup(false);
    }

    function testFundingReceiptsAreHaircutBeforeProtocolCapital() public {
        _open(alice, 10e18);
        _open(bob, -1e18);
        _seedLegacyFundingDebt(block.number + 10_000_000);
        T.SettlementQuote memory q = market.settlementQuote();
        uint256 reserve = vault.protocolReserve();
        uint256 bobFree = vault.freeBalance(bob);
        uint256 aliceFree = vault.freeBalance(alice);
        assertGt(q.haircut, 0);
        assertEq(q.capitalRequired, 0);
        vm.prank(carol);
        market.liquidate(alice, "");
        (uint256 price, uint256 haircut, uint256 profits) = market.settlementInfo();
        assertEq(price, q.price);
        assertEq(haircut, q.haircut);
        assertEq(profits, q.profits);
        assertEq(vault.protocolReserve(), reserve);
        assertEq(vault.deficit(address(market)), 0);
        assertGe(vault.freeBalance(bob), bobFree, "existing free collateral is not haircut");
        assertEq(vault.freeBalance(alice), aliceFree);
        _assertTerminal();
        _assertCash();
    }

    function testWithdrawnWinnerLeavesTerminalDeficitAndMarketCannotRestart() public {
        _open(alice, 10e18);
        _open(bob, -1e18);
        _seedLegacyFundingDebt(block.number + 40_000_000);
        _close(bob, 1e18);
        uint256 raw = vault.freeBalance(bob) / 1e12;
        vm.prank(bob);
        vault.withdraw(raw);
        uint256 bobFree = vault.freeBalance(bob);
        T.SettlementQuote memory q = market.settlementQuote();
        T.Ledger memory l = vault.ledger(address(market));
        uint256 expected = q.capitalRequired - l.creatorOwed - l.protocolOwed - vault.protocolReserve();
        assertGt(expected, 0);
        market.liquidate(alice, "");
        assertEq(vault.deficit(address(market)), expected);
        assertEq(vault.totalDeficit(), expected);
        assertEq(vault.protocolReserve(), 0);
        assertEq(vault.freeBalance(bob), bobFree);
        _assertTerminal();
        bytes32 funding = keccak256(abi.encode(market.fundingState()));
        vm.roll(block.number + 1_000_000);
        assertEq(keccak256(abi.encode(market.fundingState())), funding, "terminal funding is frozen");
        vm.expectRevert(E.MarketNotActive.selector);
        market.poke();
        vm.expectRevert(E.MarketNotActive.selector);
        market.remark();
        vm.prank(guardian);
        vm.expectRevert(E.MarketNotActive.selector);
        market.pauseOpens();
        vm.expectRevert(E.MarketNotAdmitted.selector);
        market.resumeOpens();
        vm.prank(creator);
        vm.expectRevert(E.MarketNotActive.selector);
        market.reseed(2_000_000e18);
        vm.expectRevert(E.MarketNotActive.selector);
        market.quoteOpen(1e18);
        _assertCash();
        usdc.mint(address(this), (expected + 1e12 - 1) / 1e12 + 10_000e6);
        vault.recapitalize(address(market), (expected + 1e12 - 1) / 1e12 + 10_000e6);
        assertEq(vault.totalDeficit(), 0);
        vm.expectRevert(E.MarketNotAdmitted.selector);
        market.resumeOpens();
        _assertCash();
    }

    function testFuzzTerminalLongShortFundingAndCash(uint32 blocks_, bool short, bool winnerLeft) public {
        uint256 elapsed = bound(blocks_, 10_000_000, 45_000_000);
        _open(alice, short ? -int256(10e18) : int256(10e18));
        _open(bob, short ? int256(1e18) : -int256(1e18));
        _seedLegacyFundingDebt(block.number + elapsed);
        if (winnerLeft) _close(bob, 1e18);
        market.liquidate(alice, "");
        _assertTerminal();
        _assertCash();
    }

    function _assertTerminal() internal view {
        (uint8 status,) = market.status();
        assertEq(status, uint8(T.Status.Settled));
        assertEq(market.positionCount(), 0);
        assertEq(market.longSize() + market.shortSize(), 0);
        assertEq(market.fundingRatePerBlock(), 0);
        assertEq(vault.ledger(address(market)).clearing, 0);
        assertEq(vault.ledger(address(market)).fundingPool, 0);
        T.FundingState memory f = market.fundingState();
        assertEq(f.longWeighted, 0);
        assertEq(f.shortWeighted, 0);
        assertEq(Funding.surplus(f, 0, 0, 0), 0);
        assertEq(Curve.clearing(market.ammState()), 0);
        assertEq(market.ammState().entryCostNet, 0);
        assertTrue(vault.terminalFinalized(address(market)));
    }
}

/// @dev Exposes the engine to isolate settlement valuation cases that healthy production positions cannot trigger.
contract SettlementEngineHarness is Market {
    function settleForTest() external nonReentrant {
        S.Data storage s = S.load();
        Engine.touch(s);
        Settlement.execute(s, address(0));
    }
}

contract SettlementValuationTest is MarketFixture {
    function setUp() public {
        _setup(false);
    }

    function _marketImplementation() internal override returns (address) {
        return address(new SettlementEngineHarness());
    }

    function testUnmatchedMarkProfitConsumesClearingBudgetWithoutInventingCash() public {
        _open(alice, 10e18);
        vm.roll(block.number + 300);
        T.SettlementQuote memory q = market.settlementQuote();
        assertGt(q.profits, 0);
        assertLt(q.clearing, 0);
        uint256 beforeInsurance = vault.ledger(address(market)).insurance;
        uint256 beforeFree = vault.freeBalance(alice);
        uint256 margin = market.position(alice).margin;
        SettlementEngineHarness(address(market)).settleForTest();
        assertEq(beforeInsurance - vault.ledger(address(market)).insurance, uint256(-q.clearing));
        assertEq(vault.freeBalance(alice) - beforeFree, margin + q.profits);
        assertEq(vault.ledger(address(market)).clearing, 0);
        _assertCash();
    }

    function testPositiveClearingReturnsCurveSurplusToInsurance() public {
        vm.roll(block.number + 300);
        _open(alice, 10e18);
        _open(bob, 10e18);
        _close(bob, 1e18);
        // The TWAP is still at the seed mark: both the remaining trader's loss and curve cash must be accounted.
        T.SettlementQuote memory q = market.settlementQuote();
        uint256 beforeInsurance = vault.ledger(address(market)).insurance;
        SettlementEngineHarness(address(market)).settleForTest();
        assertGt(q.clearing, 0);
        int256 net = q.clearing - int256(q.debt);
        assertEq(vault.ledger(address(market)).insurance, uint256(int256(beforeInsurance) + net));
        _assertCash();
    }
}

contract DegradedSettlementTest is DebtShockFixture {
    function setUp() public {
        _setup(true);
    }

    function _config(bool externalIndex) internal view override returns (T.MarketConfig memory c) {
        c = super._config(externalIndex);
        c.degradeAfterBlocks = 400_000_000;
    }

    function testDegradedTerminalUses300BlockTwapAndDoesNotReadOracle() public {
        _open(alice, 10e18);
        _open(bob, -1e18);
        source.set(99e18, uint64(block.number), 0);
        market.remark();
        _seedLegacyFundingDebt(block.number + 400_000_001);
        _close(bob, 0.5e18);
        vm.roll(block.number + 150);
        source.setBroken(true);
        uint256 calls = source.calls();
        uint256 degradedPrice = market.twapPrice();
        uint256 terminalPrice = market.settlementQuote().price;
        assertTrue(degradedPrice != terminalPrice, "distinct 600- and 300-block observations");
        market.liquidate(alice, "ignored");
        assertEq(source.calls(), calls);
        (uint8 status,) = market.status();
        assertEq(status, uint8(T.Status.Settled));
        (uint256 price,,) = market.settlementInfo();
        assertEq(price, terminalPrice);
        assertEq(market.positionCount(), 0);
        _assertCash();
    }
}
