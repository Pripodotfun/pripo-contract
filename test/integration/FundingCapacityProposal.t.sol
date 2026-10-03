// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Market} from "../../src/Market.sol";
import {FixedPointMath as F} from "../../src/libraries/FixedPointMath.sol";
import {FundingMath as Funding} from "../../src/libraries/FundingMath.sol";
import {RiskMath as Risk} from "../../src/libraries/RiskMath.sol";
import {MarketState as S} from "../../src/market/MarketState.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {MarketFixture} from "../helpers/MarketFixture.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Test-only proposal probe. Advances to the proposed capacity directly; it does not model elapsed-time accrual.
contract FundingCapacityProposalMarket is Market {
    function reachProposedCap(bool longsPay) external returns (address binding, uint256 increment) {
        S.Data storage s = S.load();
        int256 sideIndex = longsPay ? s._funding.longIndex : s._funding.shortIndex;
        increment = type(uint256).max;
        for (uint256 i; i < s._accounts.length; ++i) {
            address user = s._accounts[i];
            T.Position memory p = s._positions[user];
            if (p.size == 0 || (p.size > 0) != longsPay) continue;
            uint256 minimum = Math.mulDiv(p.entryCost, s._config.mmrBps, F.BPS, Math.Rounding.Ceil);
            int256 capacity = s.vault.locked(user, address(this)) - F.toInt(minimum);
            require(capacity >= 0, "probe requires nonnegative initial capacity");
            int256 capIndex = p.lastFundingIndex + F.toInt(Math.mulDiv(F.toUint(capacity), F.WAD, F.abs(p.size)));
            uint256 available = capIndex > sideIndex ? F.toUint(capIndex - sideIndex) : 0;
            if (available < increment) (binding, increment) = (user, available);
        }
        require(binding != address(0) && s.longSize != 0 && s.shortSize != 0, "probe requires two sides");
        int256 rate = longsPay ? F.toInt(increment) : -F.toInt(increment);
        s._funding = Funding.accrue(
            s._funding, s.longSize, s.shortSize, rate, F.WAD, s._funding.lastBlock + 1, s._config.receiveCapX
        );
        s._funding.lastBlock = uint64(block.number);
    }
}

/// @notice Executable checks of the proposed margin-minus-maintenance cap against existing execution rules.
contract FundingCapacityProposalTest is MarketFixture {
    function _marketImplementation() internal override returns (address) {
        return address(new FundingCapacityProposalMarket());
    }

    function testProposedCapLeavesProfitableBindingPayerHealthy() public {
        _setup(false);
        _open(alice, 1e18);
        _open(bob, 1e18);
        _open(carol, -0.1e18);
        vm.roll(block.number + 300);
        market.poke();
        (address binding,) = FundingCapacityProposalMarket(address(market)).reachProposedCap(true);
        assertEq(binding, alice);
        (,, int256 spotProfit, int256 owed) = market.quoteClose(alice, 1e18);
        uint256 maintenance = Math.mulDiv(market.position(alice).entryCost, 1500, 10_000, Math.Rounding.Ceil);
        assertGt(spotProfit, 0);
        assertEq(vault.locked(alice, address(market)) - owed, int256(maintenance));
        (int256 health, bool liquidatable) = market.health(alice);
        assertGt(health, 0.15e18, "positive reference PnL remains part of health");
        assertFalse(liquidatable, "reaching a funding cap does not imply liquidation eligibility");
        _assertCash();
    }

    function testProposedCapSpendsCurveLossCollateralBeforeVoluntaryClose() public {
        _setup(true);
        address[] memory extras = new address[](24);
        for (uint256 i; i < 12; ++i) {
            extras[i] = address(uint160(0x1000 + i));
            _deposit(extras[i], 1_000e6);
            _open(extras[i], -18e18);
        }
        _open(bob, -18e18);
        for (uint256 i; i < 12; ++i) {
            extras[12 + i] = address(uint160(0x2000 + i));
            _deposit(extras[12 + i], 1_000e6);
            _open(extras[12 + i], 18e18);
        }
        _open(alice, 18e18);
        (address binding,) = FundingCapacityProposalMarket(address(market)).reachProposedCap(false);
        assertEq(binding, bob);
        (,,, int256 owed) = market.quoteClose(bob, 1e18);
        T.Position memory p = market.position(bob);
        uint256 maintenance = Math.mulDiv(p.entryCost, 250, 10_000, Math.Rounding.Ceil);
        uint256 retained = p.margin - uint256(owed);
        assertGe(retained, maintenance);
        assertLt(retained - maintenance, 18, "index flooring leaves less than one index quantum");

        // A receiver settles before all payers; actual vault cash funds its removable receipt.
        vm.prank(alice);
        market.addMargin(1);
        assertLt(vault.ledger(address(market)).fundingPool, 0);
        uint256 required = Risk.initialMargin(market.ammState(), 18e18, market.position(alice).entryCost, 5, 250, 557);
        uint256 removable = market.position(alice).margin - required;
        vm.prank(alice);
        market.removeMargin(removable);
        uint256 withdrawal = vault.freeBalance(alice) / 1e12;
        vm.prank(alice);
        vault.withdraw(withdrawal);

        // Earlier shorts leave through normal closes. No liquidation or market-limit bypass is used.
        for (uint256 i; i < 12; ++i) {
            _close(extras[i], 1e18);
        }
        (,, int256 pnl,) = market.quoteClose(bob, 1e18);
        assertLt(int256(retained) + pnl, 0, "maintenance alone does not cover permitted curve loss");
        uint256 insuranceBefore = vault.ledger(address(market)).insurance;
        _close(bob, 1e18);
        assertLt(vault.ledger(address(market)).insurance, insuranceBefore, "the proposed cap still consumes insurance");
        _assertCashWith(extras);
        emit log_named_uint("binding entry quote WAD", p.entryCost);
        emit log_named_uint("retained maintenance quote WAD", maintenance);
        emit log_named_int("close trading PnL quote WAD", pnl);
        emit log_named_uint("net insurance draw quote WAD", insuranceBefore - vault.ledger(address(market)).insurance);
    }
}
