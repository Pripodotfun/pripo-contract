// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MarginVault} from "../../src/MarginVault.sol";
import {Market} from "../../src/Market.sol";
import {FixedPointMath as F} from "../../src/libraries/FixedPointMath.sol";
import {FundingMath as Funding} from "../../src/libraries/FundingMath.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {MarketFixture} from "../helpers/MarketFixture.sol";
import {MockUSDC} from "../helpers/MockUSDC.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

contract LiquidationHandler is Test {
    Market private market;
    MarginVault private vault;
    MockUSDC private usdc;
    address[4] private actors;
    uint256 public liquidations;

    constructor(Market m, MarginVault v, MockUSDC token, address[4] memory users) {
        market = m;
        vault = v;
        usdc = token;
        actors = users;
        token.approve(address(vault), type(uint256).max);
    }

    function advance(uint32 seed) external {
        vm.roll(block.number + bound(seed, 0, 15_000_000));
    }

    function liquidate(uint8 actor) external {
        address user = actors[actor % 4];
        if (market.position(user).size == 0) return;
        (, bool unhealthy) = market.health(user);
        if (!unhealthy) return;
        // Integer fragments in this campaign stay above the base-wei boundary; unexpected rejection fails the run.
        vm.prank(actors[(uint256(actor) + 1) % 4]);
        market.liquidate(user, "");
        ++liquidations;
    }

    function margin(uint8 actor, uint80 seed) external {
        address user = actors[actor % 4];
        if (market.position(user).size == 0) return;
        uint256 free = vault.freeBalance(user);
        if (free == 0) return;
        uint256 amount = bound(seed, 1, free < 500e18 ? free : 500e18);
        vm.prank(user);
        market.addMargin(amount);
    }

    function partialClose(uint8 actor) external {
        address user = actors[actor % 4];
        int256 size = market.position(user).size;
        if (F.abs(size) < 2) return;
        vm.prank(user);
        market.close(0.5e18, size > 0 ? 0 : type(uint256).max, "");
    }

    function withdraw(uint8 actor, uint64 seed) external {
        address user = actors[actor % 4];
        uint256 cap = vault.freeBalance(user) / 1e12;
        uint256 cash = usdc.balanceOf(address(vault));
        if (cap > cash) cap = cash;
        if (cap == 0) return;
        uint256 amount = bound(seed, 1, cap);
        vm.prank(user);
        vault.withdraw(amount);
    }

    function fund(uint64 seed) external {
        uint256 raw = bound(seed, 1, 10_000e6);
        usdc.mint(address(this), raw);
        vault.fundProtocolReserve(raw);
    }

    function allocate() external {
        vault.allocateProtocolFees(address(market), 32);
    }
}

contract LiquidationInvariantTest is StdInvariant, MarketFixture {
    LiquidationHandler private handler;
    address[4] private actors;

    function setUp() public {
        _setup(false);
        actors = [alice, bob, carol, creator];
        _open(alice, 10e18);
        _open(carol, 10e18);
        _open(bob, -20e18);
        _open(carol, 1e18);
        vm.roll(block.number + 30_000_000);
        _close(carol, uint256(2e18) / 11);
        vm.roll(block.number + 300);
        (,,, int256 owed) = market.quoteClose(alice, 1e18);
        int256 current = vault.locked(alice, address(market)) - owed;
        int256 desired = -int256(vault.ledger(address(market)).insurance) + 0.5e18;
        vm.prank(alice);
        market.addMargin(uint256(desired - current));
        handler = new LiquidationHandler(market, vault, usdc, actors);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.advance.selector;
        selectors[1] = handler.liquidate.selector;
        selectors[2] = handler.margin.selector;
        selectors[3] = handler.partialClose.selector;
        selectors[4] = handler.withdraw.selector;
        selectors[5] = handler.fund.selector;
        selectors[6] = handler.allocate.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_LiquidationCashCurveFundingAndTerminalState() public view {
        _assertCash();
        T.FundingState memory funding = market.fundingState();
        int256 entries;
        int256 longWeighted;
        int256 shortWeighted;
        uint256 longs;
        uint256 shorts;
        uint256 count;
        for (uint256 i; i < actors.length; ++i) {
            T.Position memory p = market.position(actors[i]);
            if (p.size == 0) {
                assertEq(vault.locked(actors[i], address(market)), 0);
                continue;
            }
            ++count;
            if (p.size > 0) {
                longs += F.abs(p.size);
                entries += F.toInt(p.entryCost);
                longWeighted += F.signedProduct(F.abs(p.size), p.lastFundingIndex);
            } else {
                shorts += F.abs(p.size);
                entries -= F.toInt(p.entryCost);
                shortWeighted += F.signedProduct(F.abs(p.size), p.lastFundingIndex);
            }
        }
        assertEq(market.ammState().entryCostNet, entries);
        assertEq(market.longSize(), longs);
        assertEq(market.shortSize(), shorts);
        assertEq(market.positionCount(), count);
        assertEq(funding.longWeighted, longWeighted);
        assertEq(funding.shortWeighted, shortWeighted);
        Funding.surplus(funding, vault.ledger(address(market)).fundingPool, longs, shorts);
        (uint8 status,) = market.status();
        if (vault.deficit(address(market)) != 0) assertEq(status, uint8(T.Status.Settled));
        if (status == uint8(T.Status.Settled)) {
            assertEq(count, 0);
            assertEq(market.fundingRatePerBlock(), 0);
            assertEq(vault.ledger(address(market)).clearing, 0);
            assertEq(vault.ledger(address(market)).fundingPool, 0);
        }
    }
}
