// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MarginVault} from "../../src/MarginVault.sol";
import {Market} from "../../src/Market.sol";
import {CurveMath as Curve} from "../../src/libraries/CurveMath.sol";
import {FixedPointMath as F} from "../../src/libraries/FixedPointMath.sol";
import {FundingMath as Funding} from "../../src/libraries/FundingMath.sol";
import {RiskMath as Risk} from "../../src/libraries/RiskMath.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {MarketFixture} from "../helpers/MarketFixture.sol";
import {MockUSDC} from "../helpers/MockUSDC.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

contract MarketHandler is Test {
    Market public immutable market;
    MarginVault public immutable vault;
    MockUSDC public immutable token;
    address public immutable creator;
    address[8] public actors;
    uint256 public settlementCount;
    uint256 public successfulOpens;
    uint256 public successfulCloses;

    constructor(Market m, MarginVault v, MockUSDC t, address c, address[8] memory users) {
        market = m;
        vault = v;
        token = t;
        creator = c;
        actors = users;
    }

    function open(uint8 actor, uint96 seed, bool isLong) external {
        address user = actors[actor % 8];
        T.Position memory p = market.position(user);
        uint256 capacity = 18e18 - F.abs(p.size);
        if (capacity < 1e10) return;
        uint256 amount = bound(seed, 1e10, Math.min(capacity, 5e18));
        int256 size = (p.size != 0 ? p.size > 0 : isLong) ? int256(amount) : -int256(amount);
        (uint256 average, uint256 fee, uint256 margin,) = market.quoteOpenFor(user, size);
        if (fee + margin > vault.freeBalance(user)) return;
        vm.prank(user);
        market.open(size, average, "");
        if (p.size != 0) settlementCount++;
        successfulOpens++;
        p = market.position(user);
        T.MarketConfig memory c = market.config();
        T.AmmState memory a = market.ammState();
        uint256 required = Risk.initialMargin(a, p.size, p.entryCost, c.maxLeverageX, c.mmrBps, c.sideCapBps);
        assertGe(p.margin, required, "initial margin after open");
        uint256 worst = Risk.worstClose(a, p.size > 0, F.abs(p.size), c.sideCapBps);
        int256 loss = p.size > 0 ? int256(p.entryCost) - int256(worst) : int256(worst) - int256(p.entryCost);
        assertLe(loss + int256(Math.mulDiv(p.entryCost, c.mmrBps, 10_000, Math.Rounding.Ceil)), int256(p.margin));
        assertLe(market.longSize(), Risk.sideCap(a.baseAtSeed, c.sideCapBps));
        assertLe(market.shortSize(), Risk.sideCap(a.baseAtSeed, c.sideCapBps));
        (uint256 longs, uint256 shorts, uint256 cap) = market.openInterest();
        assertLe(longs, cap);
        assertLe(shorts, cap);
    }

    function close(uint8 actor, uint64 fractionSeed) external {
        address user = actors[actor % 8];
        T.Position memory p = market.position(user);
        if (p.size == 0) return;
        uint256 fraction = fractionSeed % 4 == 0 || F.abs(p.size) < 1e10 ? 1e18 : bound(fractionSeed, 0.1e18, 1e18);
        (uint256 average,,,) = market.quoteClose(user, fraction);
        vm.prank(user);
        market.close(fraction, average, "");
        settlementCount++;
        successfulCloses++;
    }

    function advance(uint16 blocksSeed) external {
        vm.roll(block.number + bound(blocksSeed, 0, 12_000));
        market.poke();
    }

    function addMargin(uint8 actor, uint80 seed) external {
        address user = actors[actor % 8];
        if (market.position(user).size == 0 || vault.freeBalance(user) == 0) return;
        uint256 amount = bound(seed, 1, Math.min(vault.freeBalance(user), 50e18));
        vm.prank(user);
        market.addMargin(amount);
        settlementCount++;
    }

    function removeMargin(uint8 actor, uint80 seed) external {
        address user = actors[actor % 8];
        T.Position memory p = market.position(user);
        if (p.size == 0) return;
        T.MarketConfig memory c = market.config();
        uint256 required =
            Risk.initialMargin(market.ammState(), p.size, p.entryCost, c.maxLeverageX, c.mmrBps, c.sideCapBps);
        (,,, int256 owed) = market.quoteClose(user, 1e18);
        (, int256 pnl) = market.realizablePnl(user);
        int256 net = vault.locked(user, address(market)) - owed;
        int256 spare = net - int256(required);
        int256 healthSpare = net + pnl - int256(Math.ceilDiv(p.entryCost, c.maxLeverageX));
        if (healthSpare < spare) spare = healthSpare;
        if (spare <= 0) return;
        uint256 amount = bound(seed, 1, uint256(spare));
        vm.prank(user);
        market.removeMargin(amount);
        settlementCount++;
        (int256 health,) = market.health(user);
        assertGe(health, int256(uint256(1e18) / c.maxLeverageX));
    }

    function sweep() external {
        market.sweepFundingSurplus();
    }

    function claims() external {
        vm.prank(creator);
        market.claimCreatorFees();
        vm.prank(creator);
        vault.claimReferral();
        vault.claimProtocolFees(address(market));
    }

    function withdraw(uint8 actor, uint64 seed) external {
        address user = actors[actor % 8];
        uint256 available = vault.freeBalance(user) / 1e12;
        if (available == 0) return;
        uint256 raw = bound(seed, 1, available);
        vm.prank(user);
        vault.withdraw(raw);
    }

    function deposit(uint8 actor, uint64 seed) external {
        address user = actors[actor % 8];
        uint256 capacity = vault.depositCap() - token.balanceOf(address(vault));
        uint256 available = Math.min(capacity, token.balanceOf(user));
        if (available == 0) return;
        uint256 raw = bound(seed, 1, available);
        vm.prank(user);
        vault.deposit(raw);
    }
}

contract MarketInvariantTest is StdInvariant, MarketFixture {
    MarketHandler internal handler;
    address[8] internal actors;

    function setUp() public {
        _setup(false);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;
        for (uint256 i = 3; i < 8; i++) {
            actors[i] = address(uint160(0x1000 + i));
            _deposit(actors[i], 5_000e6);
        }
        vm.prank(creator);
        vault.registerReferralCode("INSURED");
        for (uint256 i; i < 8; i++) {
            vm.prank(actors[i]);
            vault.setReferrer("INSURED");
        }
        _open(alice, 10e18);
        _open(bob, -1e18);
        handler = new MarketHandler(market, vault, usdc, creator, actors);
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.open.selector;
        selectors[1] = handler.close.selector;
        selectors[2] = handler.advance.selector;
        selectors[3] = handler.addMargin.selector;
        selectors[4] = handler.removeMargin.selector;
        selectors[5] = handler.sweep.selector;
        selectors[6] = handler.claims.selector;
        selectors[7] = handler.withdraw.selector;
        selectors[8] = handler.deposit.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_ActualCashCurveFundingAndPositions() public view {
        T.AmmState memory a = market.ammState();
        T.FundingState memory f = market.fundingState();
        T.Ledger memory l = vault.ledger(address(market));
        int256 cash = int256(vault.freeBalance(creator) + vault.referralOwed(creator) + vault.protocolReserve())
            - int256(vault.totalDeficit());
        int256 entryNet;
        int256 longWeighted;
        int256 shortWeighted;
        uint256 longs;
        uint256 shorts;
        uint256 positionCount;
        for (uint256 i; i < actors.length; i++) {
            address user = actors[i];
            T.Position memory p = market.position(user);
            int256 collateral = vault.locked(user, address(market));
            cash += int256(vault.freeBalance(user)) + collateral;
            assertEq(int256(p.margin) - int256(market.positionDebt(user)), collateral);
            if (p.size > 0) {
                longs += F.abs(p.size);
                longWeighted += F.signedProduct(F.abs(p.size), p.lastFundingIndex);
                entryNet += int256(p.entryCost);
            } else if (p.size < 0) {
                shorts += F.abs(p.size);
                shortWeighted += F.signedProduct(F.abs(p.size), p.lastFundingIndex);
                entryNet -= int256(p.entryCost);
            } else {
                assertEq(collateral, 0);
                assertEq(p.entryCost, 0);
                assertEq(p.lastFundingIndex, 0);
            }
            if (p.size != 0) {
                ++positionCount;
                (,,, int256 fundingOwed) = market.quoteClose(user, 1e18);
                int256 realizedEquity = collateral + Curve.realizablePnl(a, p.size, p.entryCost) - fundingOwed;
                if (realizedEquity < 0) {
                    (, bool liquidatable) = market.health(user);
                    assertTrue(liquidatable, "unrecognized realizable insolvency");
                }
            }
        }
        cash += int256(l.insurance + l.protocolOwed + l.creatorOwed + l.skewPool) + l.clearing + l.fundingPool;
        assertEq(cash, int256(usdc.balanceOf(address(vault)) * 1e12), "actual token cash equality");
        assertEq(a.entryCostNet, entryNet);
        assertEq(l.clearing, Curve.clearing(a));
        assertEq(int256(longs) - int256(shorts), int256(a.baseAtSeed) - int256(a.baseReserve));
        assertEq(longs, market.longSize());
        assertEq(shorts, market.shortSize());
        address[] memory book = market.positionAccounts(0, 256);
        assertEq(book.length, positionCount);
        assertEq(market.positionCount(), positionCount);
        for (uint256 i; i < book.length; ++i) {
            assertTrue(market.position(book[i]).size != 0);
            for (uint256 j; j < i; ++j) {
                assertTrue(book[j] != book[i]);
            }
        }
        assertEq(f.longWeighted, longWeighted);
        assertEq(f.shortWeighted, shortWeighted);
        Funding.surplus(f, l.fundingPool, longs, shorts);
        assertLe(f.roundingHi, handler.settlementCount() * 1e18);
    }

    function afterInvariant() public {
        for (uint256 i; i < actors.length; i++) {
            if (market.position(actors[i]).size != 0) _close(actors[i], 1e18);
        }
        market.sweepFundingSurplus();
        T.AmmState memory a = market.ammState();
        T.Ledger memory l = vault.ledger(address(market));
        assertEq(a.entryCostNet, 0);
        assertEq(a.baseReserve, a.baseAtSeed);
        assertEq(a.quoteReserve, a.curveBase);
        assertEq(l.clearing, 0);
        assertEq(l.fundingPool, 0);
        uint256 insurance = l.insurance;
        market.sweepFundingSurplus();
        assertEq(vault.ledger(address(market)).insurance, insurance);
    }
}
