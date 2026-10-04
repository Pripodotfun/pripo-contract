// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MarginVault} from "../../src/MarginVault.sol";
import {Market} from "../../src/Market.sol";
import {FixedPointMath as F} from "../../src/libraries/FixedPointMath.sol";
import {FundingMath as Funding} from "../../src/libraries/FundingMath.sol";
import {RiskMath as Risk} from "../../src/libraries/RiskMath.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {MarketFixture} from "../helpers/MarketFixture.sol";
import {MockUSDC} from "../helpers/MockUSDC.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

/// @dev No liquidation, synthetic debt, recapitalization or cash-bounded withdrawals in this handler.
contract FundingBackingHandler is Test {
    Market[2] public markets;
    MarginVault public vault;
    MockUSDC public token;
    address[4] public users;
    uint256 public withdrawals;
    uint256 public receiverSettlements;
    uint256 public freezes;

    constructor(Market[2] memory ms, MarginVault v, MockUSDC t, address[4] memory us) {
        markets = ms;
        vault = v;
        token = t;
        users = us;
    }

    function advance(uint32 blocksSeed) external {
        address[2] memory beforeBinding;
        T.FundingState[2] memory beforeFunding;
        for (uint256 i; i < 2; ++i) {
            beforeBinding[i] = markets[i].fundingBinding();
            beforeFunding[i] = markets[i].fundingState();
        }
        vm.roll(block.number + bound(blocksSeed, 0, 100_000_000));
        // Both markets checkpoint the same block even if both exhaust capacity in the gap.
        for (uint256 i; i < 2; ++i) {
            markets[i].poke();
            if (markets[i].fundingBinding() != address(0)) ++freezes;
            if (beforeBinding[i] != address(0)) {
                assertEq(markets[i].fundingBinding(), beforeBinding[i]);
                assertEq(markets[i].fundingState().longIndex, beforeFunding[i].longIndex);
                assertEq(markets[i].fundingState().shortIndex, beforeFunding[i].shortIndex);
            }
        }
    }

    function open(uint8 marketSeed, uint8 userSeed, uint64 sizeSeed, bool long) external {
        Market m = markets[marketSeed % 2];
        address user = users[userSeed % 4];
        int256 oldSize = m.position(user).size;
        if (oldSize != 0 && (oldSize > 0) != long) return;
        int256 size = int256(bound(sizeSeed, 1e12, 3e18));
        if (!long) size = -size;
        // Read-only admission preflight; any unexpected mutation revert fails the invariant campaign.
        try m.quoteOpenFor(user, size) returns (uint256, uint256 fee, uint256 required, uint256) {
            if (required + fee > vault.freeBalance(user)) return;
        } catch {
            return;
        }
        address binding = m.fundingBinding();
        vm.prank(user);
        m.open(size, long ? type(uint256).max : 0, "");
        _checkUntouchedBinding(m, binding, user);
    }

    function margin(uint8 marketSeed, uint8 userSeed, uint64 amountSeed) external {
        Market m = markets[marketSeed % 2];
        address user = users[userSeed % 4];
        if (m.position(user).size == 0 || vault.freeBalance(user) == 0) return;
        uint256 amount = bound(amountSeed, 1, Math.min(vault.freeBalance(user), 100e18));
        address binding = m.fundingBinding();
        vm.prank(user);
        m.addMargin(amount);
        _checkUntouchedBinding(m, binding, user);
    }

    function remove(uint8 marketSeed, uint8 userSeed, uint64 amountSeed) external {
        Market m = markets[marketSeed % 2];
        address user = users[userSeed % 4];
        T.Position memory p = m.position(user);
        if (p.size == 0) return;
        (,,, int256 owed) = m.quoteClose(user, 1e18);
        int256 available = vault.locked(user, address(m)) - owed;
        T.MarketConfig memory cfg = m.config();
        uint256 required =
            Risk.initialMargin(m.ammState(), p.size, p.entryCost, cfg.maxLeverageX, cfg.mmrBps, cfg.sideCapBps);
        (, uint256 protectedAmount,) = m.fundingCapacity(user);
        required = Math.max(required, protectedAmount);
        (, int256 twapPnl) = m.realizablePnl(user);
        if (twapPnl < 0) required += uint256(-twapPnl);
        if (available <= int256(required)) return;
        uint256 amount = bound(amountSeed, 1, uint256(available) - required);
        address binding = m.fundingBinding();
        vm.prank(user);
        m.removeMargin(amount);
        _checkUntouchedBinding(m, binding, user);
    }

    function close(uint8 marketSeed, uint8 userSeed, bool isPartial) external {
        _close(markets[marketSeed % 2], users[userSeed % 4], isPartial);
    }

    function receiverFirst(uint8 marketSeed) external {
        Market m = markets[marketSeed % 2];
        for (uint256 i; i < 4; ++i) {
            if (m.position(users[i]).size == 0) continue;
            (,,, int256 owed) = m.quoteClose(users[i], 1e18);
            if (owed >= 0) continue;
            _close(m, users[i], false);
            ++receiverSettlements;
            _withdraw(users[i]);
        }
    }

    function withdraw(uint8 userSeed) external {
        _withdraw(users[userSeed % 4]);
    }

    function sweep(uint8 marketSeed) external {
        Market m = markets[marketSeed % 2];
        address binding = m.fundingBinding();
        m.sweepFundingSurplus();
        vault.allocateProtocolFees(address(m), 32);
        vault.claimProtocolFees(address(m));
        _checkUntouchedBinding(m, binding, address(0));
    }

    function unwind() external {
        for (uint256 j; j < 2; ++j) {
            Market m = markets[j];
            // Settle and exit every receiver before touching any payer in this market.
            for (uint256 pass; pass < 2; ++pass) {
                for (uint256 i; i < 4; ++i) {
                    if (m.position(users[i]).size == 0) continue;
                    (,,, int256 owed) = m.quoteClose(users[i], 1e18);
                    if (pass == 0 && owed >= 0) continue;
                    _close(m, users[i], false);
                    _withdraw(users[i]);
                }
            }
            m.sweepFundingSurplus();
            vm.prank(m.config().creator);
            m.claimCreatorFees();
        }
        for (uint256 i; i < 4; ++i) {
            _withdraw(users[i]);
        }
    }

    function _close(Market m, address user, bool isPartial) private {
        int256 size = m.position(user).size;
        if (size == 0) return;
        uint256 fraction = isPartial && F.abs(size) > 1 ? 0.5e18 : 1e18;
        address binding = m.fundingBinding();
        uint256 insuranceBefore = vault.ledger(address(m)).insurance;
        (, uint256 fee,,) = m.quoteClose(user, fraction);
        uint256 insuranceFee = Math.mulDiv(fee, m.config().insuranceShareBps, F.BPS);
        vm.prank(user);
        m.close(fraction, size > 0 ? 0 : type(uint256).max, "");
        assertEq(
            vault.ledger(address(m)).insurance,
            insuranceBefore + insuranceFee,
            "ordinary exits credit exactly the insurance fee without drawing coverage"
        );
        _checkUntouchedBinding(m, binding, user);
    }

    function _withdraw(address user) private {
        if (vault.referralOwed(user) != 0) {
            vm.prank(user);
            vault.claimReferral();
        }
        uint256 raw = vault.freeBalance(user) / 1e12;
        if (raw == 0) return;
        vm.prank(user);
        vault.withdraw(raw); // The amount is never reduced to actual vault cash.
        ++withdrawals;
    }

    function _checkUntouchedBinding(Market m, address previous, address touched) private view {
        if (previous != address(0) && touched != previous) assertEq(m.fundingBinding(), previous);
    }
}

contract FundingBackingInvariantTest is StdInvariant, MarketFixture {
    Market[2] private ms;
    address[4] private users;
    FundingBackingHandler private handler;

    function setUp() public {
        _setup(false);
        ms = [market, _newMarket(false)];
        users = [alice, bob, carol, creator];
        vm.prank(creator);
        vault.registerReferralCode("BACKING");
        vm.prank(alice);
        vault.setReferrer("BACKING");
        for (uint256 j; j < 2; ++j) {
            vm.prank(alice);
            ms[j].open(10e18, type(uint256).max, "");
            vm.prank(bob);
            ms[j].open(-1e18, 0, "");
        }
        handler = new FundingBackingHandler(ms, vault, usdc, users);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.advance.selector;
        selectors[1] = handler.open.selector;
        selectors[2] = handler.margin.selector;
        selectors[3] = handler.remove.selector;
        selectors[4] = handler.close.selector;
        selectors[5] = handler.receiverFirst.selector;
        selectors[6] = handler.withdraw.selector;
        selectors[7] = handler.sweep.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_CashBacksWithdrawableBalancesAndEveryPayerCapacity() public view {
        uint256 payableBalances;
        for (uint256 i; i < 4; ++i) {
            payableBalances += vault.freeBalance(users[i]) + vault.referralOwed(users[i]);
        }
        for (uint256 j; j < 2; ++j) {
            payableBalances += _checkMarket(ms[j]);
        }
        assertGe(usdc.balanceOf(address(vault)) * 1e12, payableBalances);
        assertEq(vault.protocolReserve(), 10_000e18, "funding never draws protocol reserve");
        assertEq(vault.backstopBalance(), 0);
        assertEq(vault.totalDeficit(), 0);
        _checkCashIdentity();
    }

    function testSimultaneousClampsAndReceiverFirstWithdrawalsWithoutKeepers() public {
        handler.advance(100_000_000);
        assertEq(ms[0].fundingBinding(), alice);
        assertEq(ms[1].fundingBinding(), alice);
        invariant_CashBacksWithdrawableBalancesAndEveryPayerCapacity();
        handler.receiverFirst(0);
        handler.receiverFirst(1);
        assertEq(handler.receiverSettlements(), 2);
        invariant_CashBacksWithdrawableBalancesAndEveryPayerCapacity();
        afterInvariant();
        assertGt(handler.withdrawals(), 0);
    }

    function _checkMarket(Market m) private view returns (uint256 payableBalances) {
        T.FundingState memory f = m.fundingState();
        T.Ledger memory ledger = vault.ledger(address(m));
        payableBalances = ledger.creatorOwed;
        Funding.surplus(f, ledger.fundingPool, m.longSize(), m.shortSize());
        address[2] memory minimumUser;
        int256[2] memory minimumIndex = [type(int256).max, type(int256).max];
        for (uint256 i; i < 4; ++i) {
            (int256 size, int256 cap, uint256 payableExtra) = _checkAccount(m, users[i], f);
            if (size == 0) continue;
            payableBalances += payableExtra;
            uint256 side = size > 0 ? 0 : 1;
            if (
                minimumUser[side] == address(0) || cap < minimumIndex[side]
                    || (cap == minimumIndex[side] && users[i] < minimumUser[side])
            ) {
                minimumIndex[side] = cap;
                minimumUser[side] = users[i];
            }
        }
        for (uint256 side; side < 2; ++side) {
            (address actual, int256 cap) = m.fundingLimit(side == 0);
            assertEq(actual, minimumUser[side]);
            assertEq(cap, minimumIndex[side], "heap agrees with a fresh full-book computation");
        }
        if (m.fundingBinding() != address(0)) assertEq(m.fundingRatePerBlock(), 0);
    }

    function _checkAccount(Market m, address user, T.FundingState memory f)
        private
        view
        returns (int256 size, int256 cap, uint256 payableExtra)
    {
        T.Position memory p = m.position(user);
        size = p.size;
        if (size == 0) return (0, 0, 0);
        int256 sideIndex = size > 0 ? f.longIndex : f.shortIndex;
        int256 owed = F.ceilWad(F.signedProduct(F.abs(size), sideIndex - p.lastFundingIndex));
        uint256 floor = _protected(m, p);
        int256 locked = vault.locked(user, address(m));
        uint256 capacity = locked > int256(floor) ? uint256(locked) - floor : 0;
        if (owed > 0) assertLe(uint256(owed), capacity, "payer-specific funding backing");
        int256 effective = locked - owed;
        assertGe(effective, 0, "no synthetic or accrued funding debt");
        if (effective > int256(floor)) payableExtra = uint256(effective) - floor;
        cap = p.lastFundingIndex + int256(capacity * 1e18 / F.abs(size));
    }

    function afterInvariant() public {
        handler.unwind();
        for (uint256 j; j < 2; ++j) {
            assertEq(ms[j].positionCount(), 0);
            assertEq(vault.ledger(address(ms[j])).fundingPool, 0);
            assertEq(vault.ledger(address(ms[j])).clearing, 0);
        }
        assertEq(vault.protocolReserve(), 10_000e18);
        assertEq(vault.totalDeficit(), 0);
        _checkCashIdentity();
    }

    function _checkCashIdentity() private view {
        int256 accounted = int256(vault.protocolReserve() + vault.backstopBalance());
        for (uint256 i; i < 4; ++i) {
            accounted += int256(vault.freeBalance(users[i]) + vault.referralOwed(users[i]));
        }
        for (uint256 j; j < 2; ++j) {
            address m = address(ms[j]);
            T.Ledger memory l = vault.ledger(m);
            accounted += int256(l.insurance + l.protocolOwed + l.creatorOwed + l.skewPool) + l.clearing + l.fundingPool;
            for (uint256 i; i < 4; ++i) {
                accounted += vault.locked(users[i], m);
            }
        }
        assertEq(accounted, int256(usdc.balanceOf(address(vault)) * 1e12));
    }

    function _protected(Market m, T.Position memory p) private view returns (uint256) {
        T.MarketConfig memory cfg = m.config();
        uint256 worst = Risk.worstClose(m.ammState(), p.size > 0, F.abs(p.size), cfg.sideCapBps);
        int256 loss = p.size > 0 ? int256(p.entryCost) - int256(worst) : int256(worst) - int256(p.entryCost);
        return (loss > 0 ? uint256(loss) : 0) + Math.ceilDiv(p.entryCost * cfg.mmrBps, 10_000)
            + Math.ceilDiv(worst * cfg.takerFeeBps, 10_000);
    }
}
