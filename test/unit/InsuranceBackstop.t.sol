// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {InsuranceBackstop} from "../../src/InsuranceBackstop.sol";
import {MarginVault} from "../../src/MarginVault.sol";
import {IPripoErrors as E} from "../../src/interfaces/IPripoErrors.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {MockUSDC} from "../helpers/MockUSDC.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

contract BackstopMarketStub {
    bool public immutable externalIndex;

    constructor(bool external_) {
        externalIndex = external_;
    }

    function openInterest() external pure returns (uint256, uint256, uint256) {
        return (0, 0, 25_000e18);
    }
}

contract InsuranceBackstopTest is Test {
    MarginVault private vault;
    InsuranceBackstop private backstop;
    MockUSDC private token;
    address private market;
    address private externalMarket;
    address private alice = address(0xa11ce);
    address private sponsor = address(0xb0b);
    address private keeper = address(0xbee);

    function setUp() public {
        token = new MockUSDC();
        vault = MarginVault(
            address(
                new ERC1967Proxy(
                    address(new MarginVault()),
                    abi.encodeCall(
                        MarginVault.initialize, (address(token), address(this), address(0x123), address(0x456))
                    )
                )
            )
        );
        backstop = new InsuranceBackstop(address(vault));
        vault.setBackstopController(backstop);
        market = address(new BackstopMarketStub(false));
        externalMarket = address(new BackstopMarketStub(true));
        vault.registerMarket(market, sponsor);
        vault.registerMarket(externalMarket, sponsor);
        token.mint(alice, 10_000e6);
        token.mint(sponsor, 20_000e6);
        vm.startPrank(alice);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(10_000e6);
        vault.fundInsurance(market, 100e18);
        vm.stopPrank();
        vm.startPrank(sponsor);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(20_000e6);
        vault.fundBackstop(10_000e18);
        vm.stopPrank();
    }

    function testInsuranceBeforeBackstopAndBudgetCannotReset() public {
        vm.prank(market);
        vault.settleFunding(alice, 2_000e18);
        vm.prank(market);
        (uint256 insurance, uint256 paid, uint256 remainder) = vault.coverBadDebt(alice);
        assertEq(insurance, 100e18);
        assertEq(paid, 1_000e18);
        assertEq(remainder, 900e18);
        assertEq(vault.backstopBalance(), 9_000e18);
        assertEq(backstop.capacity(market), 0);
        vm.prank(market);
        (, paid, remainder) = vault.coverBadDebt(alice);
        assertEq(paid, 0);
        assertEq(remainder, 900e18);
        vm.prank(sponsor);
        vault.fundBackstop(1_000e18);
        assertEq(backstop.capacity(market), 0);
        (uint64 start,,,) = backstop.windows(market);
        vm.roll(uint256(start) + 288_000);
        assertEq(backstop.capacity(market), 1_000e18);
        vm.prank(market);
        (, paid, remainder) = vault.coverBadDebt(alice);
        assertEq(paid, 900e18);
        assertEq(remainder, 0);
        _assertCash();
    }

    function testIndependentTwentyAndTenPercentCaps() public {
        assertEq(backstop.capacity(market), 1_000e18);
        assertEq(backstop.capacity(externalMarket), 2_000e18);
        vm.prank(externalMarket);
        vault.settleFunding(alice, 5_000e18);
        vm.prank(externalMarket);
        (, uint256 paid, uint256 remainder) = vault.coverBadDebt(alice);
        assertEq(paid, 2_000e18);
        assertEq(remainder, 3_000e18);
        assertEq(backstop.capacity(market), 800e18);
        _assertCash();
    }

    function testWindowAtGenesisDoesNotReset() public {
        vm.roll(0);
        vm.prank(market);
        vault.settleFunding(alice, 2_000e18);
        vm.prank(market);
        vault.coverBadDebt(alice);
        assertEq(backstop.capacity(market), 0);
        vm.prank(market);
        (, uint256 paid,) = vault.coverBadDebt(alice);
        assertEq(paid, 0);
    }

    function testPenaltyIsCappedAndSelfLiquidationLosesInsuranceShare() public {
        vm.prank(market);
        vault.lock(alice, 10e18);
        uint256 free = vault.freeBalance(alice);
        vm.prank(market);
        assertEq(vault.chargeLiquidationPenalty(alice, alice, 100e18), 10e18);
        assertEq(vault.freeBalance(alice) - free, 4e18);
        assertEq(vault.ledger(market).insurance, 106e18);
        vm.prank(market);
        vault.settleFunding(alice, 1e18);
        vm.prank(market);
        assertEq(vault.chargeLiquidationPenalty(alice, keeper, 10e18), 0);
        assertEq(vault.freeBalance(keeper), 0);
        _assertCash();
    }

    function testAdlTransferCannotClawBackFreeOrOverpayDebt() public {
        vm.prank(market);
        vault.lock(sponsor, 20e18);
        vm.prank(market);
        vault.settleFunding(alice, 10e18);
        uint256 free = vault.freeBalance(sponsor);
        vm.prank(market);
        vm.expectRevert(E.AccountingInvariant.selector);
        vault.transferAdlProfit(sponsor, alice, 11e18);
        vm.prank(market);
        vault.transferAdlProfit(sponsor, alice, 10e18);
        assertEq(vault.freeBalance(sponsor), free);
        assertEq(vault.locked(alice, market), 0);
        assertEq(vault.locked(sponsor, market), 10e18);
        _assertCash();
    }

    function testTopUpPreservesMarketReserveAndCash() public {
        vm.prank(sponsor);
        vault.fundInsurance(market, 6_000e18);
        uint256 amount = backstop.topUp(market);
        assertEq(amount, 1_100e18);
        assertEq(vault.ledger(market).insurance, 5_000e18);
        assertEq(vault.backstopBalance(), 11_100e18);
        assertEq(backstop.topUp(market), 0);
        _assertCash();
    }

    function testControllerAndMarketAuthorization() public {
        vm.expectRevert(E.Unauthorized.selector);
        backstop.consume(market, 1e18);
        vm.expectRevert(E.Unauthorized.selector);
        vault.moveInsuranceToBackstop(market, 1e18);
        vm.expectRevert(E.Unauthorized.selector);
        vault.coverBadDebt(alice);
        vm.expectRevert(E.Unauthorized.selector);
        backstop.topUp(address(0xdead));
        vm.expectRevert(E.InvalidConfiguration.selector);
        vault.setBackstopController(backstop);
    }

    function _assertCash() private view {
        int256 sum = int256(
            vault.freeBalance(alice) + vault.freeBalance(sponsor) + vault.freeBalance(keeper) + vault.backstopBalance()
        );
        address[2] memory markets = [market, externalMarket];
        for (uint256 i; i < 2; i++) {
            T.Ledger memory l = vault.ledger(markets[i]);
            sum += vault.locked(alice, markets[i]) + vault.locked(sponsor, markets[i]);
            sum += int256(l.insurance + l.protocolOwed + l.creatorOwed) + l.clearing + l.fundingPool;
        }
        assertEq(sum, int256(token.balanceOf(address(vault)) * 1e12));
    }
}
