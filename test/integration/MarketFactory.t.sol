// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MarginVault} from "../../src/MarginVault.sol";
import {Market} from "../../src/Market.sol";
import {IFactoryVault, MarketFactory} from "../../src/MarketFactory.sol";
import {NullAdapter} from "../../src/adapters/NullAdapter.sol";
import {PythAdapter} from "../../src/adapters/PythAdapter.sol";
import {IPripoErrors as E} from "../../src/interfaces/IPripoErrors.sol";
import {IPythPriceFeed} from "../../src/interfaces/IPythPriceFeed.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {MarketFixture} from "../helpers/MarketFixture.sol";
import {MockPyth} from "../helpers/MockPyth.sol";
import {HookUSDC} from "../helpers/MockUSDC.sol";
import {TerminalMarketStub} from "../helpers/TerminalMarketStub.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract MarketFactoryTest is MarketFixture {
    MarketFactory internal factory;
    NullAdapter internal nullSource;
    MockPyth internal provider;
    PythAdapter internal pythSource;
    bytes32 internal constant FEED = bytes32("NVDA");

    function setUp() public {
        vm.roll(1000);
        vm.warp(100_000);
        _setup(false);
        nullSource = new NullAdapter();
        provider = new MockPyth();
        pythSource = new PythAdapter(provider, 3, 300);
        provider.set(FEED, IPythPriceFeed.Price(100e8, 0, -8, block.timestamp));
        factory = new MarketFactory(IFactoryVault(address(vault)), address(new Market()), address(nullSource), true);
        vault.setRegistrar(address(factory), true);
        usdc.mint(creator, 100_000e6);
        usdc.mint(alice, 100_000e6);
        vm.prank(creator);
        usdc.approve(address(factory), type(uint256).max);
        vm.prank(alice);
        usdc.approve(address(factory), type(uint256).max);
    }

    function testDeterministicCreationFundsInsuranceAndTradesWithFixedLaunchConfig() public {
        T.CreateParams memory p = _params("SPACEX-PERP");
        address predicted = factory.predictAddress(p.symbol);
        uint256 before = usdc.balanceOf(creator);
        vm.prank(creator);
        Market created = Market(factory.createMarket(p));
        assertEq(address(created), predicted);
        assertEq(usdc.balanceOf(creator), before - p.seedBond);
        assertEq(vault.registrarOf(predicted), address(factory));
        assertEq(vault.creatorOf(predicted), creator);
        assertEq(vault.ledger(predicted).insurance, 2_000e18);
        assertEq(vault.freeBalance(address(factory)), 0);
        assertEq(usdc.balanceOf(address(factory)), 0);
        assertEq(usdc.allowance(address(factory), address(vault)), 0);
        assertEq(factory.marketCount(), 1);
        assertEq(factory.markets(0), predicted);
        assertTrue(factory.isMarket(predicted));
        (address recorded, uint64 at, string memory symbol) = factory.marketInfo(predicted);
        assertEq(recorded, creator);
        assertEq(at, block.number);
        assertEq(symbol, p.symbol);
        T.MarketConfig memory c = created.config();
        assertEq(c.maxLeverageX, 2);
        assertEq(c.sideCapBps, 1715);
        assertEq(c.maxPositionsPerMarket, 128);
        assertEq(c.adlPendingWindow, 1000);
        vm.prank(alice);
        created.open(1e18, type(uint256).max, "");
        vm.prank(alice);
        created.close(1e18, 0, "");
        assertEq(created.positionCount(), 0);
        vm.prank(creator);
        created.transferCreator(bob);
        assertEq(vault.creatorOf(predicted), bob);
        (recorded,,) = factory.marketInfo(predicted);
        assertEq(recorded, creator); // Creation metadata is historical.
    }

    function testSymbolFeedAndKindRulesRejectAtomically() public {
        T.CreateParams memory p = _params("UNIQUE");
        vm.prank(creator);
        factory.createMarket(p);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarketFactory.SymbolUnavailable.selector, keccak256(bytes(p.symbol))));
        factory.createMarket(p);
        p.symbol = "BAD";
        p.priceSource = address(pythSource);
        p.feedId = FEED;
        p.seedBond = 5_000e6;
        vm.prank(creator);
        vm.expectPartialRevert(MarketFactory.FeedUnavailable.selector);
        factory.createMarket(p);
        p = _params("BAD");
        p.feedId = FEED;
        vm.prank(creator);
        vm.expectRevert(E.InvalidOracle.selector);
        factory.createMarket(p);
        p.feedId = 0;
        p.symbol = "";
        vm.prank(creator);
        vm.expectRevert(E.InvalidConfiguration.selector);
        factory.createMarket(p);
        p.symbol = string(new bytes(65));
        vm.prank(creator);
        vm.expectRevert(E.InvalidConfiguration.selector);
        factory.createMarket(p);
        assertEq(factory.marketCount(), 1);
    }

    function testRejectedCreationRollsBackCloneRegistrationBondAndSymbol() public {
        T.CreateParams memory p = _params("RETRY");
        uint256 before = usdc.balanceOf(creator);
        address predicted = factory.predictAddress(p.symbol);
        p.depth = 1e18;
        vm.prank(creator);
        vm.expectRevert(E.InvalidReserves.selector);
        factory.createMarket(p);
        assertEq(predicted.code.length, 0);
        assertEq(vault.registrarOf(predicted), address(0));
        assertEq(factory.marketForSymbol(keccak256(bytes(p.symbol))), address(0));
        assertEq(factory.marketCount(), 0);
        assertEq(usdc.balanceOf(creator), before);
        assertEq(vault.ledger(predicted).insurance, 0);
        p.depth = 2_000_000e18;
        vm.prank(creator);
        assertEq(factory.createMarket(p), predicted);
    }

    function testPythListingAndOneTransactionPullCreationIgnoresCreatorPrice() public {
        _enablePyth();
        vm.prank(alice);
        factory.listFeed(address(pythSource), FEED);
        assertTrue(factory.allowedFeeds(address(pythSource), FEED));
        assertEq(factory.refundableBonds(), 500e6);
        T.CreateParams memory p = _params("NVDA-PERP");
        p.priceSource = address(pythSource);
        p.feedId = FEED;
        p.seedBond = 5_000e6;
        p.initialPrice = 1; // External price is authoritative.
        bytes[] memory payload = new bytes[](1);
        payload[0] = abi.encode(FEED, IPythPriceFeed.Price(150e8, 0, -8, vm.getBlockTimestamp()));
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        Market created = Market(factory.createMarket{value: 1}(p, abi.encode(payload)));
        assertTrue(created.externalIndex());
        (uint256 price,,) = created.indexPrice();
        assertEq(price, 150e18);
        assertEq(created.config().maxLeverageX, 5);
        assertEq(created.config().sideCapBps, 557);
        assertEq(factory.marketForFeed(address(pythSource), FEED), address(created));
        assertEq(address(factory).balance + address(pythSource).balance + address(created).balance, 0);
        assertEq(address(provider).balance, 1);
        p.symbol = "NVDA-AGAIN";
        vm.prank(creator);
        vm.expectPartialRevert(MarketFactory.FeedUnavailable.selector);
        factory.createMarket(p);
        assertEq(usdc.balanceOf(address(factory)), factory.refundableBonds());
    }

    function testListingRefundIsDelayedCannotBeRedirectedAndDoesNotRevokeFeed() public {
        _enablePyth();
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        factory.listFeed(address(pythSource), FEED);
        (, uint64 at,,) = factory.feedListings(address(pythSource), FEED);
        vm.warp(at - 1);
        vm.expectRevert(MarketFactory.ListingNotRefundable.selector);
        factory.refundFeedBond(address(pythSource), FEED);
        vm.warp(at);
        vm.prank(bob);
        factory.refundFeedBond(address(pythSource), FEED);
        assertEq(usdc.balanceOf(alice), before);
        assertEq(factory.refundableBonds(), 0);
        assertTrue(factory.allowedFeeds(address(pythSource), FEED));
        vm.expectRevert(MarketFactory.ListingNotRefundable.selector);
        factory.refundFeedBond(address(pythSource), FEED);
        vm.prank(creator);
        vm.expectPartialRevert(MarketFactory.FeedUnavailable.selector);
        factory.listFeed(address(pythSource), FEED);
    }

    function testGovernorSlashSeparatesRevocationFromBoundedReserveAllocation() public {
        _enablePyth();
        vm.prank(alice);
        factory.listFeed(address(pythSource), FEED);
        vm.prank(guardian);
        vm.expectRevert(E.Unauthorized.selector);
        factory.slashFeed(address(pythSource), FEED, keccak256("wrong quote asset"));
        factory.slashFeed(address(pythSource), FEED, keccak256("wrong quote asset"));
        assertFalse(factory.allowedFeeds(address(pythSource), FEED));
        assertEq(factory.slashedBonds(), 500e6);
        assertEq(factory.refundableBonds(), 0);
        assertEq(usdc.balanceOf(address(factory)), 500e6);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.expectRevert(MarketFactory.ListingNotRefundable.selector);
        factory.refundFeedBond(address(pythSource), FEED);
        factory.allocateSlashedBonds(200e6);
        assertEq(vault.protocolReserve(), 10_200e18);
        assertEq(factory.slashedBonds(), 300e6);
        factory.allocateSlashedBonds(300e6);
        assertEq(vault.protocolReserve(), 10_500e18);
        assertEq(usdc.balanceOf(address(factory)), 0);
        vm.expectRevert(E.InvalidConfiguration.selector);
        factory.allocateSlashedBonds(1);
    }

    function testAdapterDelayGuardianCancellationAndAuthorization() public {
        vm.prank(alice);
        vm.expectRevert(E.Unauthorized.selector);
        factory.scheduleAdapter(address(pythSource));
        factory.scheduleAdapter(address(pythSource));
        uint256 at = factory.adapterReadyAt(address(pythSource));
        vm.warp(at - 1);
        vm.expectPartialRevert(MarketFactory.GovernanceNotReady.selector);
        factory.activateAdapter(address(pythSource));
        vm.prank(guardian);
        factory.disableAdapter(address(pythSource));
        vm.warp(at);
        vm.expectPartialRevert(MarketFactory.GovernanceNotReady.selector);
        factory.activateAdapter(address(pythSource));
        _enablePyth();
        vm.prank(guardian);
        factory.disableAdapter(address(pythSource));
        vm.prank(alice);
        vm.expectPartialRevert(MarketFactory.FeedUnavailable.selector);
        factory.listFeed(address(pythSource), FEED);
    }

    function testImplementationDelayPreservesExistingClonesAndSymbols() public {
        vm.prank(creator);
        address first = factory.createMarket(_params("OLD"));
        bytes memory oldCode = first.code;
        address next = address(new Market());
        factory.scheduleImplementation(next);
        uint256 at = factory.implementationReadyAt();
        vm.warp(at - 1);
        vm.expectPartialRevert(MarketFactory.GovernanceNotReady.selector);
        factory.activateImplementation();
        vm.prank(guardian);
        factory.cancelImplementation();
        vm.warp(at);
        vm.expectPartialRevert(MarketFactory.GovernanceNotReady.selector);
        factory.activateImplementation();
        factory.scheduleImplementation(next);
        vm.warp(factory.implementationReadyAt());
        vm.prank(alice);
        factory.activateImplementation();
        assertEq(factory.marketImplementation(), next);
        assertEq(first.code, oldCode);
        assertEq(factory.predictAddress("OLD"), first);
        address predicted = factory.predictAddress("NEW");
        vm.prank(creator);
        assertEq(factory.createMarket(_params("NEW")), predicted);
        assertTrue(predicted.code.length != 0);
    }

    function testFixedReserveAdmitsMoreMarketsAndUnderfilledFloorReturnsBond() public {
        for (uint256 i; i < 12; ++i) {
            vm.prank(creator);
            factory.createMarket(_params(vm.toString(i)));
        }
        assertEq(vault.reserveFloor(), 10_000e18);
        assertEq(vault.aggregateReserveBudget(), 0);
        TerminalMarketStub dead = new TerminalMarketStub();
        vault.registerMarket(address(dead), creator);
        vm.prank(address(dead));
        vault.settleFunding(address(0xdead), 1e18);
        dead.setState(T.Status.Settled, 0, 0);
        address[] memory debtors = new address[](1);
        debtors[0] = address(0xdead);
        vm.prank(address(dead));
        vault.finalizeSettlement(debtors);
        T.CreateParams memory p = _params("UNDERFUNDED-FLOOR");
        address predicted = factory.predictAddress(p.symbol);
        uint256 before = usdc.balanceOf(creator);
        vm.prank(creator);
        vm.expectPartialRevert(E.ReserveBelowFloor.selector);
        factory.createMarket(p);
        assertEq(factory.marketCount(), 12);
        assertEq(predicted.code.length, 0);
        assertEq(usdc.balanceOf(creator), before);
        assertEq(vault.registrarOf(predicted), address(0));
    }

    function testBackstopDestinationIsFixedAndAllocationLeavesNoFactoryFreeBalance() public {
        MarketFactory alternate = new MarketFactory(
            IFactoryVault(address(vault)), factory.marketImplementation(), address(nullSource), false
        );
        alternate.scheduleAdapter(address(pythSource));
        vm.warp(alternate.adapterReadyAt(address(pythSource)));
        alternate.activateAdapter(address(pythSource));
        vm.prank(alice);
        usdc.approve(address(alternate), 500e6);
        vm.prank(alice);
        alternate.listFeed(address(pythSource), FEED);
        alternate.slashFeed(address(pythSource), FEED, keccak256("misconfigured"));
        alternate.allocateSlashedBonds(500e6);
        assertEq(vault.backstopBalance(), 500e18);
        assertEq(vault.protocolReserve(), 10_000e18);
        assertEq(vault.freeBalance(address(alternate)), 0);
        assertEq(usdc.balanceOf(address(alternate)), 0);
        _assertCash();
    }

    function testOracleBootstrapCannotReenterFactory() public {
        factory.scheduleAdapter(address(source));
        vm.warp(factory.adapterReadyAt(address(source)));
        factory.activateAdapter(address(source));
        source.set(100e18, uint64(block.number), 0);
        vm.prank(alice);
        factory.listFeed(address(source), FEED);
        source.setCallback(
            address(factory),
            abi.encodeWithSignature(
                "createMarket((string,address,bytes32,uint256,uint256,uint256))", _params("REENTER")
            )
        );
        T.CreateParams memory p = _params("SOURCE");
        p.priceSource = address(source);
        p.feedId = FEED;
        p.seedBond = 5_000e6;
        vm.prank(creator);
        factory.createMarket(p);
        assertFalse(source.callbackSucceeded());
        assertEq(source.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(factory.marketCount(), 1);
        assertEq(factory.marketForSymbol(keccak256("REENTER")), address(0));
    }

    function testTokenCallbackAndTransferTaxCannotLeavePartialCreation() public {
        HookUSDC hooked = new HookUSDC();
        MarginVault target = MarginVault(
            address(
                new ERC1967Proxy(
                    address(new MarginVault()),
                    abi.encodeCall(MarginVault.initialize, (address(hooked), address(this), guardian, treasury))
                )
            )
        );
        hooked.mint(address(this), 10_000e6);
        hooked.approve(address(target), 10_000e6);
        target.fundProtocolReserve(10_000e6);
        MarketFactory guarded = new MarketFactory(
            IFactoryVault(address(target)), factory.marketImplementation(), address(nullSource), true
        );
        target.setRegistrar(address(guarded), true);
        hooked.mint(creator, 10_000e6);
        vm.prank(creator);
        hooked.approve(address(guarded), type(uint256).max);
        hooked.configureIncomingHook(true);
        hooked.configure(
            address(guarded),
            abi.encodeWithSignature(
                "createMarket((string,address,bytes32,uint256,uint256,uint256))", _params("REENTER")
            ),
            false
        );
        vm.prank(creator);
        guarded.createMarket(_params("GUARDED"));
        assertFalse(hooked.hookSucceeded());
        assertEq(hooked.hookResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        hooked.configure(address(0), "", true);
        address predicted = guarded.predictAddress("TAXED");
        uint256 before = hooked.balanceOf(creator);
        vm.prank(creator);
        vm.expectRevert(E.UnsupportedToken.selector);
        guarded.createMarket(_params("TAXED"));
        assertEq(hooked.balanceOf(creator), before);
        assertEq(predicted.code.length, 0);
        assertEq(guarded.marketCount(), 1);
        assertEq(target.registrarOf(predicted), address(0));
    }

    function testFuzzFeedEscrowConservesAcrossRefundsSlashesAndAllocation(uint8 countSeed, uint8 choices) public {
        uint256 count = bound(countSeed, 1, 8);
        _enablePyth();
        for (uint256 i; i < count; ++i) {
            bytes32 id = bytes32(i + 1);
            provider.set(id, IPythPriceFeed.Price(100e8, 0, -8, vm.getBlockTimestamp()));
            vm.prank(alice);
            factory.listFeed(address(pythSource), id);
        }
        uint256 before = usdc.balanceOf(alice);
        uint256 refunds;
        vm.warp(vm.getBlockTimestamp() + 30 days);
        for (uint256 i; i < count; ++i) {
            bytes32 id = bytes32(i + 1);
            if (choices & (uint256(1) << i) != 0) {
                factory.slashFeed(address(pythSource), id, keccak256("misconfigured"));
            } else {
                factory.refundFeedBond(address(pythSource), id);
                refunds += 500e6;
            }
            assertEq(usdc.balanceOf(address(factory)), factory.refundableBonds() + factory.slashedBonds());
            vm.expectRevert(MarketFactory.ListingNotRefundable.selector);
            factory.refundFeedBond(address(pythSource), id);
        }
        assertEq(usdc.balanceOf(alice), before + refunds);
        uint256 slashed = factory.slashedBonds();
        if (slashed != 0) factory.allocateSlashedBonds(slashed);
        assertEq(vault.protocolReserve(), 10_000e18 + slashed * 1e12);
        assertEq(usdc.balanceOf(address(factory)), 0);
        assertEq(factory.refundableBonds() + factory.slashedBonds(), 0);
    }

    function _params(string memory symbol) internal view returns (T.CreateParams memory) {
        return T.CreateParams(symbol, address(nullSource), 0, 100e18, 2_000_000e18, 2_000e6);
    }

    function _enablePyth() internal {
        factory.scheduleAdapter(address(pythSource));
        vm.warp(factory.adapterReadyAt(address(pythSource)));
        factory.activateAdapter(address(pythSource));
    }
}
