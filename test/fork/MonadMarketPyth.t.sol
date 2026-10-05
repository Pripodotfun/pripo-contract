// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MarginVault} from "../../src/MarginVault.sol";
import {Market} from "../../src/Market.sol";
import {IFactoryVault, MarketFactory} from "../../src/MarketFactory.sol";
import {NullAdapter} from "../../src/adapters/NullAdapter.sol";
import {IMarginVault} from "../../src/interfaces/IMarginVault.sol";
import {IPripoErrors as E} from "../../src/interfaces/IPripoErrors.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {MonadSignedPythFixture} from "./MonadSignedPyth.t.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Production trading against native USDC and a real signed BTC control observation.
abstract contract MonadMarketPythFixture is MonadSignedPythFixture {
    MarginVault internal vault;
    Market internal market;
    IERC20Metadata internal usdc;
    address internal bob;

    function setUp() public virtual override {
        super.setUp();
        usdc = IERC20Metadata(vm.parseJsonAddress(config, ".usdc"));
        vault = MarginVault(
            address(
                new ERC1967Proxy(
                    address(new MarginVault()),
                    abi.encodeCall(
                        MarginVault.initialize,
                        (address(usdc), address(this), makeAddr("guardian"), makeAddr("treasury"))
                    )
                )
            )
        );
        bob = makeAddr("signed-bob");
        deal(address(usdc), address(this), 50_000e6);
        deal(address(usdc), bob, 5_000e6);
        usdc.approve(address(vault), type(uint256).max);
        vault.fundProtocolReserve(10_000e6);
        vault.deposit(30_000e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(5_000e6);
        vm.stopPrank();
        adapter.getPrice{value: fee}(feed, abi.encode(updates));
        Market implementation = Market(_marketImplementation());
        MarketFactory factory =
            new MarketFactory(IFactoryVault(address(vault)), address(implementation), address(new NullAdapter()), true);
        market = Market(Clones.clone(address(implementation)));
        vault.registerMarket(address(market), address(this));
        vault.fundInsurance(address(market), 5_000e18);
        market.initialize(
            IMarginVault(address(vault)),
            feed,
            true,
            factory.launchConfig(address(this), address(adapter)),
            0,
            2_000_000e18
        );
    }

    function _marketImplementation() internal virtual returns (address) {
        return address(new Market());
    }
}

contract MonadMarketPythTest is MonadMarketPythFixture {
    function testSignedOpenNativeUsdcRoundTripAndExactCustody() public {
        uint256 gasBefore = gasleft();
        market.open{value: fee}(0.01e18, type(uint256).max, abi.encode(updates));
        emit log_named_uint("BTC signed market open local gross gas", gasBefore - gasleft());
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        market.open{value: fee}(-0.001e18, 0, abi.encode(updates));
        market.close(1e18, 0, "");
        vm.prank(bob);
        market.close(1e18, type(uint256).max, "");
        market.sweepFundingSurplus();
        market.claimCreatorFees();
        vault.withdraw(vault.freeBalance(address(this)) / 1e12);
        vm.startPrank(bob);
        vault.withdraw(vault.freeBalance(bob) / 1e12);
        vm.stopPrank();
        assertEq(market.positionCount(), 0);
        assertEq(address(market).balance, 0);
        assertEq(address(adapter).balance, 0);
        T.Ledger memory l = vault.ledger(address(market));
        assertEq(l.fundingPool, 0);
        assertEq(l.clearing, 0);
        assertEq(
            usdc.balanceOf(address(vault)) * 1e12,
            vault.protocolReserve() + l.insurance + l.protocolOwed + l.creatorOwed + vault.freeBalance(address(this))
                + vault.freeBalance(bob)
        );
    }

    function testExpiredRealPayloadRejectsOpenAndDegradesWithoutBlockingClose() public {
        market.open{value: fee}(0.01e18, type(uint256).max, abi.encode(updates));
        vm.warp(block.timestamp + 31);
        vm.roll(block.number + 104);
        market.poke();
        (uint8 status,) = market.status();
        assertEq(status, uint8(T.Status.Degraded));
        assertEq(market.fundingRatePerBlock(), 0);
        vm.expectRevert(E.MarketNotActive.selector);
        market.open{value: fee}(0.001e18, type(uint256).max, abi.encode(updates));
        market.close(1e18, 0, "");
        assertEq(market.positionCount(), 0);
        assertEq(vault.deficit(address(market)), 0);
        assertEq(vault.protocolReserve(), 10_000e18);
    }
}
