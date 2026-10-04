// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FixedPointMath as F} from "../../src/libraries/FixedPointMath.sol";
import {MarketState as S} from "../../src/market/MarketState.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {AdlFixture} from "../helpers/AdlFixture.sol";
import {DebtShockMarket} from "../helpers/DebtShockFixture.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Seeds only a valid persisted cursor; all positions, prices and custody use the production runtime.
contract CursorSeedMarket is DebtShockMarket {
    function seedCursor(address user, uint32 cursor) external {
        S.Data storage s = S.load();
        require(s._pendingAdl[user].active && cursor <= s._accounts.length, "invalid test cursor");
        s._pendingAdl[user].cursor = cursor;
    }
}

contract MarketAdlFallbackTest is AdlFixture {
    function setUp() public {
        _setup(false);
    }

    function _marketImplementation() internal override returns (address) {
        return address(new CursorSeedMarket());
    }

    function testFuzzRuntimeFallbackTerminatesAcrossCursorsAndWinnerCloses(
        uint8 cursorSeed,
        uint256 changes,
        bool short
    ) public {
        _prepareSplit(short, 8e18);
        market.liquidate(alice, "", new address[](0));
        uint32 cursor = uint32(bound(cursorSeed, 0, 4));
        CursorSeedMarket(address(market)).seedCursor(alice, cursor);
        vm.roll(block.number + market.config().adlPendingWindow);
        T.FundingState memory frozen = market.fundingState();
        for (uint256 step; step < 12 && market.pendingAdl(alice).active; ++step) {
            T.AdlPending memory before = market.pendingAdl(alice);
            if (step < 3) {
                address closing = changes & 1 == 0 ? bob : creator;
                if (market.position(closing).size != 0 && changes & 2 != 0) {
                    uint256 slot = market.position(closing).slot;
                    address other = closing == bob ? creator : bob;
                    uint256 otherSlot = market.position(other).slot;
                    _close(closing, changes & 4 == 0 ? 0.5e18 : 1e18);
                    if (market.position(closing).size != 0) assertEq(market.position(closing).slot, slot);
                    if (market.position(other).size != 0) assertEq(market.position(other).slot, otherSlot);
                }
            }
            uint256 eligible = _eligible(before);
            uint256 needed = before.S0 - before.matchedSize;
            assertEq(market.adlEligibleSize(alice), eligible);
            vm.recordLogs();
            market.completeAdl(alice, 1 + changes % 4);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            bool proven;
            for (uint256 i; i < logs.length; ++i) {
                if (
                    logs[i].emitter == address(market)
                        && logs[i].topics[0] == keccak256("AdlInsufficient(address,address,uint256,uint256)")
                ) {
                    (uint256 found, uint256 required) = abi.decode(logs[i].data, (uint256, uint256));
                    assertEq(found, eligible);
                    assertEq(required, needed);
                    assertLt(found, required);
                    proven = true;
                }
            }
            (uint8 status,) = market.status();
            assertEq(status == uint8(T.Status.Settled), eligible < needed);
            assertEq(proven, eligible < needed);
            T.AdlPending memory afterCall = market.pendingAdl(alice);
            if (afterCall.active) {
                assertTrue(afterCall.matchedSize > before.matchedSize || afterCall.cursor != before.cursor);
                assertEq(afterCall.S0, before.S0);
                assertEq(afterCall.E0, before.E0);
                assertEq(afterCall.V0, before.V0);
                assertEq(afterCall.since, before.since);
                assertEq(market.fundingState().longIndex, frozen.longIndex);
                assertEq(market.fundingState().shortIndex, frozen.shortIndex);
            }
            _assertCash();
            changes = uint256(keccak256(abi.encode(changes, step)));
            vm.roll(block.number + 1);
        }
        assertFalse(market.pendingAdl(alice).active, "finite mutation schedule must terminate");
        assertEq(vault.adlReservedTotal(address(market)), 0);
    }

    function _eligible(T.AdlPending memory pending) internal view returns (uint256 total) {
        address[2] memory winners = [bob, creator];
        for (uint256 i; i < winners.length; ++i) {
            T.Position memory p = market.position(winners[i]);
            if (p.size == 0) continue;
            (, int256 profit) = market.realizablePnl(winners[i]);
            (,,, int256 owed) = market.quoteClose(winners[i], 1e18);
            if (profit <= 0 || vault.locked(winners[i], address(market)) - owed < 0) continue;
            uint256 entry = p.entryCost * pending.S0;
            uint256 value = uint256(pending.V0) * F.abs(p.size);
            if (p.size > 0 ? value > entry : entry > value) total += F.abs(p.size);
        }
    }
}
