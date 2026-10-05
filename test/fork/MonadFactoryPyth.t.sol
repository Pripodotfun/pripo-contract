// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MarginVault} from "../../src/MarginVault.sol";
import {Market} from "../../src/Market.sol";
import {IFactoryVault, MarketFactory} from "../../src/MarketFactory.sol";
import {NullAdapter} from "../../src/adapters/NullAdapter.sol";
import {IPripoErrors as E} from "../../src/interfaces/IPripoErrors.sol";
import {IPythPriceFeed} from "../../src/interfaces/IPythPriceFeed.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {MonadSignedPythFixture} from "./MonadSignedPyth.t.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Full factory admission with native USDC, signed Pyth data and a real elapsed governance delay.
contract MonadFactoryPythTest is MonadSignedPythFixture {
    MarginVault internal vault;
    MarketFactory internal factory;
    IERC20Metadata internal usdc;
    address internal creator;
    address internal lister;
    address internal trader;

    function setUp() public override {
        super.setUp();
        vm.skip(!vm.keyExistsJson(report, ".governanceFork.block"), "Capture a historical governance anchor");
        uint256 signedFork = vm.activeFork();
        uint256 signedTimestamp = vm.getBlockTimestamp();
        vm.makePersistent(address(adapter));
        vm.createSelectFork("monad", vm.parseJsonUint(report, ".governanceFork.block"));
        assertEq(vm.getBlockTimestamp(), vm.parseJsonUint(report, ".governanceFork.timestamp"));
        assertGe(signedTimestamp - vm.getBlockTimestamp(), 1 days);

        usdc = IERC20Metadata(vm.parseJsonAddress(config, ".usdc"));
        MarginVault vaultImplementation = new MarginVault();
        vault = MarginVault(
            address(
                new ERC1967Proxy(
                    address(vaultImplementation),
                    abi.encodeCall(
                        MarginVault.initialize,
                        (address(usdc), address(this), makeAddr("guardian"), makeAddr("treasury"))
                    )
                )
            )
        );
        Market implementation = new Market();
        NullAdapter nullSource = new NullAdapter();
        factory = new MarketFactory(IFactoryVault(address(vault)), address(implementation), address(nullSource), true);
        vault.setRegistrar(address(factory), true);
        factory.scheduleAdapter(address(adapter));
        vm.expectPartialRevert(MarketFactory.GovernanceNotReady.selector);
        factory.activateAdapter(address(adapter));
        vm.makePersistent(address(vaultImplementation), address(vault), address(implementation));
        vm.makePersistent(address(nullSource), address(factory));

        // Carry only local deployments forward. Pyth and USDC come from the signed capture's real fork state.
        vm.selectFork(signedFork);
        assertEq(vm.getBlockTimestamp(), signedTimestamp);
        assertGe(vm.getBlockTimestamp(), factory.adapterReadyAt(address(adapter)));
        vm.prank(makeAddr("activation-caller"));
        factory.activateAdapter(address(adapter));
        assertTrue(factory.allowedAdapters(address(adapter)));
        assertEq(factory.adapterReadyAt(address(adapter)), 0);

        creator = makeAddr("factory-creator");
        lister = makeAddr("factory-lister");
        trader = makeAddr("factory-trader");
        deal(address(usdc), address(this), 10_000e6);
        deal(address(usdc), creator, 20_000e6);
        deal(address(usdc), lister, 500e6);
        deal(address(usdc), trader, 2_000e6);
        vm.deal(creator, 1 ether);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(creator);
        usdc.approve(address(factory), type(uint256).max);
        vm.prank(lister);
        usdc.approve(address(factory), 500e6);
        if (!adapter.isSupported(feed)) adapter.getPrice{value: fee}(feed, abi.encode(updates));
        vm.prank(lister);
        factory.listFeed(address(adapter), feed);
        _assertEscrow(500e6, 0);
    }

    function testFactorySignedCreationTradesAndWithdrawsNativeUsdc() public {
        vault.fundProtocolReserve(10_000e6);
        T.CreateParams memory p = _params();
        address predicted = factory.predictAddress(p.symbol);
        uint256 before = usdc.balanceOf(creator);
        uint256 gasBefore = gasleft();
        vm.prank(creator);
        Market created = Market(factory.createMarket{value: fee}(p, abi.encode(updates)));
        emit log_named_uint("signed factory creation local gross gas", gasBefore - gasleft());
        assertEq(address(created), predicted);
        assertEq(
            predicted.code,
            abi.encodePacked(
                hex"363d3d373d3d3d363d73", factory.marketImplementation(), hex"5af43d82803e903d91602b57fd5bf3"
            )
        );
        assertEq(usdc.balanceOf(creator), before - p.seedBond);
        assertEq(vault.registrarOf(predicted), address(factory));
        assertEq(vault.creatorOf(predicted), creator);
        assertEq(factory.marketForSymbol(keccak256(bytes(p.symbol))), predicted);
        assertEq(factory.marketForFeed(address(adapter), feed), predicted);
        assertEq(factory.marketCount(), 1);
        assertEq(factory.markets(0), predicted);
        assertTrue(factory.isMarket(predicted));
        (address recorded, uint64 createdAt, string memory symbol) = factory.marketInfo(predicted);
        assertEq(recorded, creator);
        assertEq(createdAt, vm.getBlockNumber());
        assertEq(symbol, p.symbol);
        (uint256 index,,) = created.indexPrice();
        assertEq(index, uint256(uint64(provider.getPriceUnsafe(feed).price)) * 1e10);
        assertEq(created.config().maxLeverageX, 5);
        assertEq(created.config().maxPositionsPerMarket, 128);
        assertEq(vault.ledger(predicted).insurance, 5_000e18);
        assertEq(vault.freeBalance(address(factory)), 0);
        assertEq(usdc.allowance(address(factory), address(vault)), 0);
        assertEq(address(factory).balance + address(adapter).balance + predicted.balance, 0);
        _assertEscrow(500e6, 0);

        vm.deal(trader, 1 ether);
        vm.startPrank(trader);
        usdc.approve(address(vault), 2_000e6);
        vault.deposit(2_000e6);
        created.open{value: fee}(0.01e18, type(uint256).max, abi.encode(updates));
        created.close(1e18, 0, "");
        vault.withdraw(vault.freeBalance(trader) / 1e12);
        vm.stopPrank();
        vm.prank(creator);
        created.claimCreatorFees();
        T.Ledger memory ledger = vault.ledger(predicted);
        assertEq(created.positionCount(), 0);
        assertEq(vault.locked(trader, predicted), 0);
        assertEq(ledger.clearing, 0);
        assertEq(ledger.fundingPool, 0);
        assertEq(
            usdc.balanceOf(address(vault)) * 1e12,
            vault.protocolReserve() + ledger.insurance + ledger.creatorOwed + ledger.protocolOwed
                + vault.freeBalance(trader)
        );

        p.symbol = "BTC-DUPLICATE";
        vm.prank(creator);
        vm.expectPartialRevert(MarketFactory.FeedUnavailable.selector);
        factory.createMarket(p);
        assertEq(factory.marketCount(), 1);
    }

    function testRejectedInitializationRollsBackBondCloneAndRegistriesThenRetries() public {
        vault.fundProtocolReserve(10_000e6);
        T.CreateParams memory p = _params();
        p.depth = 1;
        IPythPriceFeed.Price memory cached = provider.getPriceUnsafe(feed);
        vm.prank(creator);
        vm.expectRevert(E.InvalidReserves.selector);
        factory.createMarket{value: fee}(p, abi.encode(updates));
        _assertUncreated(p);
        _assertPrice(provider.getPriceUnsafe(feed), cached);
        assertEq(usdc.balanceOf(address(vault)), 10_000e6);
        p.depth = 2_000_000e18;
        address predicted = factory.predictAddress(p.symbol);
        vm.prank(creator);
        address created = factory.createMarket{value: fee}(p, abi.encode(updates));
        assertEq(created, predicted);
    }

    function testReserveAdmissionReturnsSeedBondUntilActualCashArrives() public {
        T.CreateParams memory p = _params();
        vm.prank(creator);
        vm.expectPartialRevert(E.ReserveBelowFloor.selector);
        factory.createMarket{value: fee}(p, abi.encode(updates));
        _assertUncreated(p);
        assertEq(usdc.balanceOf(address(vault)), 0);
        vault.fundProtocolReserve(10_000e6);
        vm.prank(creator);
        factory.createMarket{value: fee}(p, abi.encode(updates));
        assertEq(vault.protocolReserve(), 10_000e18);
        assertEq(usdc.balanceOf(address(vault)), 15_000e6);
    }

    function testInvalidSignatureFeeAndStaleCreationCannotConsumeTheBond() public {
        vault.fundProtocolReserve(10_000e6);
        T.CreateParams memory p = _params();
        vm.prank(creator);
        vm.expectRevert(E.UnexpectedValue.selector);
        factory.createMarket{value: fee + 1}(p, abi.encode(updates));
        _assertUncreated(p);
        bytes[] memory corrupt = _updates(".controlUpdate.updates");
        corrupt[0][corrupt[0].length - 1] ^= bytes1(uint8(1));
        vm.prank(creator);
        vm.expectRevert();
        factory.createMarket{value: fee}(p, abi.encode(corrupt));
        _assertUncreated(p);
        vm.warp(vm.getBlockTimestamp() + 4);
        vm.roll(vm.getBlockNumber() + 14);
        vm.prank(creator);
        vm.expectRevert(bytes4(keccak256("StalePrice()")));
        factory.createMarket{value: fee}(p, abi.encode(updates));
        _assertUncreated(p);
    }

    function testNativeUsdcListingRefundWaitsAndAlwaysPaysLister() public {
        (, uint64 refundAt,,) = factory.feedListings(address(adapter), feed);
        vm.warp(refundAt - 1);
        vm.expectRevert(MarketFactory.ListingNotRefundable.selector);
        factory.refundFeedBond(address(adapter), feed);
        _assertEscrow(500e6, 0);
        vm.warp(refundAt);
        vm.prank(trader);
        factory.refundFeedBond(address(adapter), feed);
        assertEq(usdc.balanceOf(lister), 500e6);
        assertEq(usdc.balanceOf(trader), 2_000e6);
        assertTrue(factory.allowedFeeds(address(adapter), feed));
        _assertEscrow(0, 0);
        vm.expectRevert(MarketFactory.ListingNotRefundable.selector);
        factory.refundFeedBond(address(adapter), feed);
    }

    function testNativeUsdcSlashedEscrowRefillsReserveInBatches() public {
        factory.slashFeed(address(adapter), feed, keccak256("incorrect feed configuration"));
        assertFalse(factory.allowedFeeds(address(adapter), feed));
        _assertEscrow(0, 500e6);
        vm.prank(trader);
        factory.allocateSlashedBonds(200e6);
        assertEq(vault.protocolReserve(), 200e18);
        _assertEscrow(0, 300e6);
        factory.allocateSlashedBonds(300e6);
        assertEq(vault.protocolReserve(), 500e18);
        assertEq(usdc.balanceOf(address(vault)), 500e6);
        _assertEscrow(0, 0);
        assertEq(usdc.allowance(address(factory), address(vault)), 0);
        vm.expectRevert(MarketFactory.ListingNotRefundable.selector);
        factory.refundFeedBond(address(adapter), feed);
    }

    function _params() internal view returns (T.CreateParams memory) {
        return T.CreateParams("BTC-PERP", address(adapter), feed, 1, 2_000_000e18, 5_000e6);
    }

    function _assertEscrow(uint256 refundable, uint256 slashed) internal view {
        assertEq(factory.refundableBonds(), refundable);
        assertEq(factory.slashedBonds(), slashed);
        assertEq(usdc.balanceOf(address(factory)), refundable + slashed);
    }

    function _assertUncreated(T.CreateParams memory p) internal view {
        address predicted = factory.predictAddress(p.symbol);
        assertEq(predicted.code.length, 0);
        assertEq(factory.marketCount(), 0);
        assertFalse(factory.isMarket(predicted));
        assertEq(factory.marketForSymbol(keccak256(bytes(p.symbol))), address(0));
        assertEq(factory.marketForFeed(address(adapter), feed), address(0));
        assertEq(vault.registrarOf(predicted), address(0));
        assertEq(vault.creatorOf(predicted), address(0));
        assertEq(vault.ledger(predicted).insurance, 0);
        assertEq(vault.freeBalance(address(factory)), 0);
        assertEq(usdc.allowance(address(factory), address(vault)), 0);
        assertEq(usdc.balanceOf(creator), 20_000e6);
        assertEq(creator.balance, 1 ether);
        assertEq(address(factory).balance + address(adapter).balance + predicted.balance, 0);
        _assertEscrow(500e6, 0);
    }
}
