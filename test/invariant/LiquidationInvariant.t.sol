// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MarginVault} from "../../src/MarginVault.sol";
import {Market} from "../../src/Market.sol";
import {FixedPointMath as F} from "../../src/libraries/FixedPointMath.sol";
import {FundingMath as Funding} from "../../src/libraries/FundingMath.sol";
import {RiskMath as Risk} from "../../src/libraries/RiskMath.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {DebtShockFixture} from "../helpers/DebtShockFixture.sol";
import {MockUSDC} from "../helpers/MockUSDC.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

contract LiquidationHandler is Test {
    Market private market;
    MarginVault private vault;
    MockUSDC private usdc;
    address[4] private actors;
    uint256 public liquidations;
    mapping(address => bytes32) public scheduleHash;

    modifier frozenFunding() {
        uint256 pendingBefore = market.pendingAdlCount();
        T.FundingState memory before = market.fundingState();
        _;
        if (pendingBefore != 0) {
            T.FundingState memory afterCall = market.fundingState();
            assertEq(afterCall.longIndex, before.longIndex);
            assertEq(afterCall.shortIndex, before.shortIndex);
        }
    }

    constructor(Market m, MarginVault v, MockUSDC token, address[4] memory users) {
        market = m;
        vault = v;
        usdc = token;
        actors = users;
        token.approve(address(vault), type(uint256).max);
    }

    function advance(uint32 seed) external frozenFunding {
        vm.roll(block.number + bound(seed, 0, 15_000_000));
    }

    function liquidate(uint8 actor) external frozenFunding {
        address user = actors[actor % 4];
        if (market.position(user).size == 0) return;
        (, bool unhealthy) = market.health(user);
        if (!unhealthy) return;
        // Explicit omissions exercise reservations and continuations. Unexpected rejection fails the run.
        vm.prank(actors[(uint256(actor) + 1) % 4]);
        if (actor & 4 == 0) market.liquidate(user, "", new address[](0));
        else market.liquidate(user, "");
        T.AdlPending memory pending = market.pendingAdl(user);
        if (pending.active) {
            scheduleHash[user] = keccak256(
                abi.encode(
                    pending.S0,
                    pending.E0,
                    pending.V0,
                    pending.M0,
                    pending.budget,
                    pending.since,
                    pending.allowanceFromC,
                    pending.allowanceFromReserve
                )
            );
        }
        ++liquidations;
    }

    function margin(uint8 actor, uint80 seed) external frozenFunding {
        address user = actors[actor % 4];
        if (market.position(user).size == 0) return;
        uint256 free = vault.freeBalance(user);
        if (free == 0) return;
        uint256 amount = bound(seed, 1, free < 500e18 ? free : 500e18);
        vm.prank(user);
        market.addMargin(amount);
    }

    function partialClose(uint8 actor) external frozenFunding {
        address user = actors[actor % 4];
        T.Position memory position = market.position(user);
        int256 size = position.size;
        if (F.abs(size) < 2 || position.adlPending) return;
        (, uint256 fee, int256 pnl, int256 owed) = market.quoteClose(user, 0.5e18);
        int256 marginBefore = vault.locked(user, address(market)) - owed;
        uint256 amount = F.abs(size) / 2;
        uint256 remainder = F.abs(size) - amount;
        uint256 entry = position.entryCost - Math.mulDiv(position.entryCost, amount, F.abs(size));
        uint256 worst = Risk.worstClose(market.ammState(), size > 0, remainder, market.config().sideCapBps);
        int256 loss = size > 0 ? int256(entry) - int256(worst) : int256(worst) - int256(entry);
        uint256 required = (loss > 0 ? uint256(loss) : 0)
            + Math.mulDiv(worst, market.config().takerFeeBps, 10_000, Math.Rounding.Ceil);
        if (marginBefore >= 0 && marginBefore + pnl - int256(fee) < int256(required)) return;
        vm.prank(user);
        market.close(0.5e18, size > 0 ? 0 : type(uint256).max, "");
    }

    function complete(uint8 actor, uint8 iterations) external frozenFunding {
        address user = actors[actor % 4];
        T.AdlPending memory pending = market.pendingAdl(user);
        if (!pending.active) return;
        uint256 ready = uint256(pending.since) + market.config().adlPendingWindow;
        if (block.number < ready) vm.roll(ready);
        market.completeAdl(user, bound(iterations, 1, 64));
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

contract LiquidationInvariantTest is StdInvariant, DebtShockFixture {
    LiquidationHandler private handler;
    address[4] private actors;

    function setUp() public {
        _setup(false);
        actors = [alice, bob, carol, creator];
        _open(alice, 10e18);
        _open(carol, 10e18);
        _open(bob, -20e18);
        _open(carol, 1e18);
        _seedLegacyFundingDebt(block.number + 30_000_000);
        _close(carol, uint256(2e18) / 11);
        vm.roll(block.number + 300);
        (,,, int256 owed) = market.quoteClose(alice, 1e18);
        int256 current = vault.locked(alice, address(market)) - owed;
        int256 desired = -int256(vault.ledger(address(market)).insurance) + 0.5e18;
        vm.prank(alice);
        market.addMargin(uint256(desired - current));
        handler = new LiquidationHandler(market, vault, usdc, actors);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.advance.selector;
        selectors[1] = handler.liquidate.selector;
        selectors[2] = handler.margin.selector;
        selectors[3] = handler.partialClose.selector;
        selectors[4] = handler.withdraw.selector;
        selectors[5] = handler.fund.selector;
        selectors[6] = handler.allocate.selector;
        selectors[7] = handler.complete.selector;
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
        uint256 pendingCount;
        uint256 reservations;
        for (uint256 i; i < actors.length; ++i) {
            T.Position memory p = market.position(actors[i]);
            T.AdlPending memory pending = market.pendingAdl(actors[i]);
            T.AdlReservation memory r = vault.adlReservation(address(market), actors[i]);
            uint256 reserved = r.lossCoverage + r.allowanceFromCoverage + r.allowanceFromReserve;
            reservations += reserved;
            assertEq(vault.adlReserved(address(market), actors[i]), reserved);
            assertEq(p.adlPending, pending.active);
            assertEq(r.active, pending.active);
            if (pending.active) {
                ++pendingCount;
                assertEq(
                    keccak256(
                        abi.encode(
                            pending.S0,
                            pending.E0,
                            pending.V0,
                            pending.M0,
                            pending.budget,
                            pending.since,
                            pending.allowanceFromC,
                            pending.allowanceFromReserve
                        )
                    ),
                    handler.scheduleHash(actors[i])
                );
                assertLe(pending.allowanceConsumed, pending.chunksMatched);
                assertLe(pending.chunksMatched, market.config().maxPositionsPerMarket);
                assertEq(r.consumedCoverage, pending.consumedC);
                assertEq(
                    r.lossCoverage + pending.consumedC + pending.replacedC, pending.reservedC - pending.allowanceFromC
                );
                assertEq(
                    r.allowanceFromCoverage + r.allowanceFromReserve + pending.allowanceConsumed,
                    pending.allowanceFromC + pending.allowanceFromReserve
                );
                assertEq(p.entryCost, pending.E0 - pending.E0 * pending.matchedSize / pending.S0);
            } else {
                assertEq(reserved, 0);
            }
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
        assertEq(market.pendingAdlCount(), pendingCount);
        assertEq(vault.adlReservationCount(address(market)), pendingCount);
        assertEq(vault.adlReservedTotal(address(market)), reservations);
        if (pendingCount != 0) assertEq(market.fundingRatePerBlock(), 0);
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
