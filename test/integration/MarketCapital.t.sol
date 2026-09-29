// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Market} from "../../src/Market.sol";
import {IMarginVault} from "../../src/interfaces/IMarginVault.sol";
import {IPripoErrors as E} from "../../src/interfaces/IPripoErrors.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {MarketFixture} from "../helpers/MarketFixture.sol";
import {TerminalMarketStub} from "../helpers/TerminalMarketStub.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

contract MarketCapitalTest is MarketFixture {
    function setUp() public {
        _setup(false);
    }

    function testTerminalDeficitBlocksOwnerAndOperatorOpensButAllowsExit() public {
        _open(alice, 1e18);
        address operator = address(0x0f);
        vm.prank(bob);
        vault.setOperator(operator, T.OperatorPolicy(uint64(block.number + 100), 2_000e18, 10_000e18, 0, 0, true));
        address dead = _terminalDebt(10_001e18);
        vm.prank(bob);
        vm.expectPartialRevert(E.ProtocolDeficit.selector);
        market.open(1e18, type(uint256).max, "");
        vm.prank(operator);
        vm.expectPartialRevert(E.ProtocolDeficit.selector);
        market.openFor(bob, 1e18, type(uint256).max, "");
        (,,, uint128 used,,) = vault.operators(bob, operator);
        assertEq(used, 0);
        assertEq(market.position(bob).size, 0);
        _close(alice, 1e18);
        vm.prank(alice);
        vault.withdraw(1e6);
        assertEq(market.position(alice).size, 0);
        assertEq(vault.deficit(dead), 1e18);
        usdc.mint(address(this), 1e6);
        vault.recapitalize(dead, 1e6);
        vm.prank(bob);
        vm.expectPartialRevert(E.ReserveBelowFloor.selector);
        market.open(1e18, type(uint256).max, "");
        usdc.mint(address(this), 10_000e6);
        vault.fundProtocolReserve(10_000e6);
        _open(bob, 1e18);
        assertGt(market.position(bob).size, 0);
        (uint8 state,) = TerminalMarketStub(dead).status();
        assertEq(state, uint8(T.Status.Settled));
    }

    function testReserveFloorBlocksAdmissionAndGovernorResumeUntilRefilled() public {
        uint256 budget = vault.aggregateReserveBudget();
        vm.prank(guardian);
        market.pauseOpens();
        _terminalDebt(1e18);
        assertEq(vault.aggregateReserveBudget(), budget, "paused market retains its admitted budget");
        vm.expectPartialRevert(E.ReserveBelowFloor.selector);
        market.resumeOpens();
        assertTrue(market.guardianPaused());
        Market clone = Market(Clones.clone(address(new Market())));
        vault.registerMarket(address(clone), creator);
        vm.prank(creator);
        vault.fundInsurance(address(clone), 2_000e18);
        T.MarketConfig memory c = _config(false);
        vm.expectPartialRevert(E.ReserveBelowFloor.selector);
        clone.initialize(IMarginVault(address(vault)), 0, false, c, 100e18, 2_000_000e18);
        assertFalse(vault.marketAdmitted(address(clone)));
        assertEq(vault.aggregateReserveBudget(), budget);
        usdc.mint(address(this), 1e6);
        vault.fundProtocolReserve(1e6);
        clone.initialize(IMarginVault(address(vault)), 0, false, c, 100e18, 2_000_000e18);
        market.resumeOpens();
        _open(bob, 1e18);
    }

    function _terminalDebt(uint256 amount) private returns (address dead) {
        dead = address(new TerminalMarketStub());
        vault.registerMarket(dead, creator);
        vm.prank(dead);
        vault.settleFunding(address(0xdead), int256(amount));
        TerminalMarketStub(dead).setState(T.Status.Settled, 0, 0);
        address[] memory debtors = new address[](1);
        debtors[0] = address(0xdead);
        vm.prank(dead);
        vault.finalizeSettlement(debtors);
    }
}
