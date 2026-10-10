// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MarketFixture} from "../helpers/MarketFixture.sol";
import {MockUSDC} from "../helpers/MockUSDC.sol";
import {MarginVault} from "../../src/MarginVault.sol";
import {Market} from "../../src/Market.sol";
import {MarketFactory, IFactoryVault} from "../../src/MarketFactory.sol";
import {Resolver} from "../../src/Resolver.sol";
import {NullAdapter} from "../../src/adapters/NullAdapter.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {IPripoErrors as E} from "../../src/interfaces/IPripoErrors.sol";
import {CurveMath as Curve} from "../../src/libraries/CurveMath.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract HandoffLifecycleTest is MarketFixture {
    MarketFactory internal factory;
    Resolver internal resolver;
    NullAdapter internal nullSource;
    address internal operator = address(0xa6e17);
    address[5] internal council = [address(101), address(102), address(103), address(104), address(105)];

    function setUp() public {
        vm.warp(10 days);
        vm.roll(1000);
        usdc = new MockUSDC();
        vault = MarginVault(address(new ERC1967Proxy(address(new MarginVault()), abi.encodeCall(MarginVault.initialize, (address(usdc), address(this), guardian, treasury)))));
        usdc.mint(address(this), 10_000e6);
        usdc.approve(address(vault), type(uint256).max);
        vault.fundProtocolReserve(10_000e6);
        _deposit(alice, 10_000e6);
        _deposit(bob, 10_000e6);
        _deposit(carol, 10_000e6);
        nullSource = new NullAdapter();
        factory = new MarketFactory(IFactoryVault(address(vault)), address(new Market()), address(nullSource), true);
        vault.setRegistrar(address(factory), true);
        resolver = new Resolver(factory, council);
        factory.setResolver(address(resolver));
        usdc.mint(creator, 10_000e6);
        vm.prank(creator);
        usdc.approve(address(factory), type(uint256).max);
        T.CreateParams memory params = _params("PRIPO:DEMO");
        vm.prank(creator);
        market = Market(factory.createMarketWithMetadata(params, "Demo Company", ""));
        usdc.mint(alice, 5_000e6);
        usdc.mint(bob, 5_000e6);
        vm.prank(alice);
        usdc.approve(address(resolver), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(resolver), type(uint256).max);
    }

    function _params(string memory symbol) internal view returns (T.CreateParams memory p) {
        p.symbol = symbol; p.priceSource = address(nullSource); p.initialPrice = 100e18; p.seedBond = 1_000e6;
        (,,p.depth) = factory.creationEconomics(p.seedBond);
    }

    function _policy(uint128 maxPosition, uint128 dailyLoss, uint16 leverage) internal {
        T.OperatorPolicy memory policy = T.OperatorPolicy(uint64(block.number + 1_000_000), 2_000e18, 2_000e18, 0, bytes32(0), true);
        vm.prank(alice);
        vault.setOperatorWithLimits(operator, policy, T.OperatorLimits(maxPosition, dailyLoss, leverage), "Research agent");
    }

    function _declareAndPropose(uint256 price) internal {
        vm.prank(creator);
        resolver.declareSettlement(address(market), 0, uint64(block.timestamp), "https://example.org/event");
        vm.prank(alice);
        resolver.propose(address(market), price, "https://example.org/closing-price");
    }

    function testMetadataEconomicsDepthAndCash() public view {
        (string memory company, bool preIpo) = factory.marketMetadata(address(market));
        assertEq(company, "Demo Company"); assertTrue(preIpo);
        assertEq(market.config().creatorShareBps, 2000);
        assertEq(vault.insuranceCap(address(market)), 10_000e18);
        (,,uint256 cap) = market.openInterest(); assertEq(cap, 50_000e18);
        T.AmmState memory a = market.ammState();
        int256 size = Curve.sizeForNotional(a, true, 15_000e18);
        T.Fill memory fill = Curve.quote(a, size);
        assertApproxEqAbs(fill.newMark, 101e18, 1000);
        _assertCash();
    }

    function testInvalidTagsAndWrongDepthCannotConsumeBondOrSymbol() public {
        T.CreateParams memory p = _params("PRIPO:bad");
        uint256 before = usdc.balanceOf(creator);
        vm.prank(creator); vm.expectRevert(E.InvalidConfiguration.selector);
        factory.createMarketWithMetadata(p, "Invalid", "");
        p = _params("PRIPO:GOOD"); p.depth--;
        vm.prank(creator); vm.expectRevert(E.InvalidReserves.selector);
        factory.createMarketWithMetadata(p, "Valid", "");
        assertEq(usdc.balanceOf(creator), before); assertEq(factory.marketCount(), 1);
    }

    function testInsuranceCapOverflowBalancesBackstop() public {
        vm.prank(alice); vault.fundInsurance(address(market), 10_000e18);
        assertEq(vault.ledger(address(market)).insurance, 10_000e18);
        assertEq(vault.backstopBalance(), 1_000e18);
        (,,uint256 cap) = market.openInterest(); assertEq(cap, 50_000e18);
        _assertCash();
    }

    function testCombinedPositionLimitRollsBackFillFeeAndAllowance() public {
        _policy(150e18, 100e18, 2);
        vm.prank(operator); market.openFor(alice, 1e18, type(uint256).max, "");
        uint256 free = vault.freeBalance(alice);
        T.AmmState memory before = market.ammState();
        vm.prank(operator); vm.expectRevert(abi.encodeWithSelector(E.PolicyViolation.selector, uint8(6)));
        market.openFor(alice, 1e18, type(uint256).max, "");
        assertEq(market.position(alice).size, 1e18);
        assertEq(market.ammState().quoteReserve, before.quoteReserve);
        assertEq(vault.freeBalance(alice), free);
        _assertCash();
    }

    function testLowerLeverageLocksExtraMarginAndCloseDoesNotConsumeOpenAllowance() public {
        _policy(1_000e18, 100e18, 1);
        vm.prank(operator); market.openFor(alice, 1e18, type(uint256).max, "");
        T.Position memory p = market.position(alice);
        assertEq(p.margin, p.entryCost);
        (,,,uint128 used,,) = vault.operators(alice, operator);
        vm.prank(operator); market.closeFor(alice, 1e18, 0, "");
        (,,,uint128 afterUsed,,) = vault.operators(alice, operator);
        assertEq(afterUsed, used); assertEq(market.position(alice).size, 0);
        _assertCash();
    }

    function testDailyLossIsOwnerWideCannotResetByReplacingPolicyAndAllowsClose() public {
        _policy(1_000e18, 1e18, 2);
        _open(alice, 1e18);
        _close(alice, 1e18);
        uint256 lost = vault.dailyRealizedLoss(alice); assertGt(lost, 0);
        _policy(1_000e18, uint128(lost), 2);
        vm.prank(operator); vm.expectRevert(abi.encodeWithSelector(E.PolicyViolation.selector, uint8(8)));
        market.openFor(alice, 1e18, type(uint256).max, "");
        // A new UTC day resets only the day budget; the existing policy remains.
        vm.warp(block.timestamp + 1 days);
        _policy(1_000e18, 100e18, 2);
        vm.prank(operator); market.openFor(alice, 1e18, type(uint256).max, "");
        _policy(1_000e18, 1, 2);
        vm.prank(operator); market.closeFor(alice, 1e18, 0, "");
        _assertCash();
    }

    function testRevocationAndUnauthorizedEntry() public {
        _policy(1_000e18, 100e18, 2);
        vm.prank(alice); vault.revokeOperator(operator);
        vm.prank(operator); vm.expectRevert(abi.encodeWithSelector(E.PolicyViolation.selector, uint8(1)));
        market.openFor(alice, 1e18, type(uint256).max, "");
        vm.expectRevert(E.Unauthorized.selector); market.beginResolution();
        vm.expectRevert(E.Unauthorized.selector); market.finalizeResolution(100e18);
        vm.prank(bob); vm.expectRevert(E.Unauthorized.selector);
        resolver.declareSettlement(address(market), 0, uint64(block.timestamp), "Evidence");
    }

    function testUncontestedSettlementFreezesAndClaimsExactlyOnce() public {
        _open(alice, 1e18); _open(bob, -1e18);
        _declareAndPropose(110e18);
        vm.prank(alice); vm.expectRevert(E.MarketNotActive.selector); market.close(1e18, 0, "");
        T.FundingState memory frozen = market.fundingState();
        vm.warp(block.timestamp + 24 hours); vm.roll(block.number + 288_000);
        assertEq(market.fundingState().longIndex, frozen.longIndex);
        resolver.finalize(address(market));
        assertEq(resolver.state(address(market)), 3);
        assertEq(market.positionCount(), 0);
        uint256 payout = market.settlementClaim(alice); assertGt(payout, 0);
        uint256 before = vault.freeBalance(alice);
        vm.prank(alice); market.claimSettlement();
        assertEq(vault.freeBalance(alice), before + payout); assertEq(market.settlementClaim(alice), 0);
        vm.prank(alice); vm.expectRevert(E.ZeroAmount.selector); market.claimSettlement();
        assertEq(resolver.credits(alice), 2_500e6);
        vm.prank(alice); resolver.claimBonds();
        assertEq(usdc.balanceOf(address(resolver)), 0);
        _assertCash();
    }

    function testDisputedSettlementNeedsThreeDistinctVotesAndExactBondWaterfall() public {
        _open(alice, 1e18); _declareAndPropose(110e18);
        vm.prank(bob); resolver.disputeWithReason(address(market), 95e18, "Wrong closing auction price");
        vm.prank(council[0]); resolver.councilResolve(address(market), 95e18);
        vm.prank(council[0]); vm.expectRevert(E.InvalidConfiguration.selector); resolver.councilResolve(address(market), 95e18);
        vm.prank(council[1]); resolver.councilResolve(address(market), 95e18);
        assertEq(resolver.state(address(market)), 2);
        vm.prank(council[2]); resolver.councilResolve(address(market), 95e18);
        assertEq(resolver.state(address(market)), 3);
        assertEq(resolver.credits(bob), 3_750e6); assertEq(resolver.credits(alice), 0);
        assertEq(usdc.balanceOf(address(resolver)), 3_750e6);
        (uint256 price,,) = market.settlementInfo(); assertEq(price, 95e18);
        _assertCash();
    }

    function testTimeoutRefundsBothBondsAndUsesCapturedTwap() public {
        _open(alice, 1e18); _declareAndPropose(1e28);
        uint256 twap = resolver.resolution(address(market)).frozenTwap;
        vm.prank(bob); resolver.dispute(address(market), 1);
        vm.expectRevert(E.InvalidConfiguration.selector); resolver.expireDispute(address(market));
        vm.warp(block.timestamp + 48 hours);
        resolver.expireDispute(address(market));
        (uint256 price,,) = market.settlementInfo(); assertEq(price, twap);
        assertEq(resolver.credits(alice), 2_500e6); assertEq(resolver.credits(bob), 2_500e6);
        _assertCash();
    }

    function testUndeclaredActiveMarketCannotBeProposedButStaleCan() public {
        vm.prank(alice); vm.expectRevert(E.MarketNotActive.selector); resolver.propose(address(market), 100e18, "Evidence");
        vm.warp(block.timestamp + 30 days);
        vm.prank(alice); resolver.startStaleWindDown(address(market));
        assertEq(resolver.state(address(market)), 1);
    }

    function testFuzzSettlementPricePreservesCashAndCannotClaimAnotherAccount(uint96 inputPrice) public {
        uint256 price = bound(uint256(inputPrice), 1, 1_000_000e18);
        _open(alice, 1e18); _open(bob, -1e18);
        _declareAndPropose(price); vm.warp(block.timestamp + 24 hours);
        (,,, uint256 expectedPayout) = market.resolutionAccountQuote(alice, price);
        resolver.finalize(address(market));
        assertEq(market.settlementClaim(alice), expectedPayout);
        _assertCash();
        vm.prank(carol); vm.expectRevert(E.ZeroAmount.selector); market.claimSettlement();
        uint256 payout = market.settlementClaim(alice);
        if (payout != 0) { vm.prank(alice); market.claimSettlement(); }
        _assertCash();
    }
    function testImplementationsFitEvmCodeSizeLimit() public {
        assertLe(address(new MarginVault()).code.length, 24_576);
        assertLe(address(new Market()).code.length, 24_576);
        assertLe(address(factory).code.length, 24_576);
        assertLe(address(resolver).code.length, 24_576);
    }

    function testFullBookWithScopedKeysSettlesWithinGasBudget() public {
        address[] memory users = new address[](128);
        for (uint256 i; i < users.length; ++i) {
            users[i] = address(uint160(0x10000 + i));
            _deposit(users[i], 20e6);
            vm.prank(users[i]);
            vault.setOperatorWithLimits(operator, T.OperatorPolicy(uint64(block.number + 1_000_000), 100e18, 100e18, 0, bytes32(0), true), T.OperatorLimits(100e18, 20e18, 2), "Agent");
            vm.prank(operator);
            market.openFor(users[i], i % 2 == 0 ? int256(0.1e18) : -int256(0.1e18), i % 2 == 0 ? type(uint256).max : 0, "");
        }
        _declareAndPropose(80e18);
        vm.warp(block.timestamp + 24 hours);
        uint256 beforeGas = gasleft();
        resolver.finalize(address(market));
        uint256 used = beforeGas - gasleft();
        emit log_named_uint("128 scoped-key positions optimistic settlement gross gas", used);
        assertLt(used, 20_000_000);
        _assertCashWith(users);
    }

    function testPublicNameOnlyChangesTheCallingWalletLabel() public {
        vm.prank(alice);
        factory.setProfileName("alice-research");
        vm.prank(bob);
        factory.setProfileName("bob");
        assertEq(factory.profileName(alice), "alice-research");
        assertEq(factory.profileName(bob), "bob");
        vm.prank(alice);
        vm.expectRevert(E.InvalidConfiguration.selector);
        factory.setProfileName("<script>");
    }

}
