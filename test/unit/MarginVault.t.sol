// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MarginVault} from "../../src/MarginVault.sol";
import {IPripoErrors as E} from "../../src/interfaces/IPripoErrors.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {HookUSDC, MockUSDC} from "../helpers/MockUSDC.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Test} from "forge-std/Test.sol";

contract MarginVaultTest is Test {
    MarginVault internal vault;
    MockUSDC internal usdc;
    address internal alice = address(0xa11ce);
    address internal bob = address(0xb0b);
    address internal operator = address(0xabc);
    address internal guardian = address(0xdef);
    address internal treasury = address(0x123);

    function setUp() public {
        usdc = new MockUSDC();
        vault = MarginVault(
            address(
                new ERC1967Proxy(
                    address(new MarginVault()),
                    abi.encodeCall(MarginVault.initialize, (address(usdc), address(this), guardian, treasury))
                )
            )
        );
        vault.registerMarket(address(this), bob);
        usdc.mint(address(this), 10_000e6);
        usdc.approve(address(vault), type(uint256).max);
        vault.fundProtocolReserve(10_000e6);
        vault.admitMarket(25_000e18, uint64(uint256(0.005e18) / 12_000));
        usdc.mint(alice, 100_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(10_000e6);
        vm.stopPrank();
    }

    function testCustodyAndIsolation() public {
        vault.lock(alice, 200e18);
        assertEq(vault.freeBalance(alice), 9_800e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(E.InsufficientMargin.selector, 9_800e18, 10_000e18));
        vault.withdraw(10_000e6);
        vault.release(alice, 100e18);
        vm.prank(alice);
        vault.withdraw(9_900e6);
        assertEq(usdc.balanceOf(address(vault)), 10_100e6);
        assertEq(vault.locked(alice, address(this)), 100e18);
        vm.prank(operator);
        vm.expectRevert(E.Unauthorized.selector);
        vault.settlePnl(alice, 100e18);
    }

    function testBalancedDebtFundingAndInsurance() public {
        vm.prank(alice);
        vault.fundInsurance(address(this), 1_000e18);
        vault.lock(alice, 100e18);
        vault.settleFunding(alice, 150e18);
        assertEq(vault.locked(alice, address(this)), -50e18);
        assertEq(vault.ledger(address(this)).fundingPool, 150e18);
        vault.settlePnl(alice, -20e18);
        assertEq(vault.coverDebt(alice), 70e18);
        T.Ledger memory l = vault.ledger(address(this));
        assertEq(l.insurance, 930e18);
        assertEq(l.clearing, 20e18);
        assertEq(int256(vault.freeBalance(alice) + l.insurance) + l.clearing + l.fundingPool, 10_000e18);
        vault.sweepFunding(1e18);
        assertEq(vault.ledger(address(this)).fundingPool, 149e18);
        assertEq(vault.ledger(address(this)).insurance, 931e18);
    }

    function testPositiveTradingProfitCanLeaveFundingDebtOnFullClose() public {
        vault.lock(alice, 100e18);
        vault.settleFunding(alice, 102e18);
        assertEq(vault.locked(alice, address(this)), -2e18);
        vault.settlePnl(alice, 1e18);
        assertEq(vault.locked(alice, address(this)), -1e18);
        vm.expectRevert(abi.encodeWithSelector(E.InsufficientMargin.selector, 0, 1));
        vault.release(alice, 1);
        assertEq(vault.locked(alice, address(this)), -1e18, "a profitable full close still needs debt recovery");
    }

    function testPositivePartialEquityCannotReleaseOverRemainingFundingDebt() public {
        vault.lock(alice, 100e18);
        vault.settleFunding(alice, 110e18);
        // Half of a position with 20 USDC full trading profit has 10 profit and -5 allocated margin.
        // The apparent 5 USDC slice payout would leave -5 collateral on the remaining position.
        vault.settlePnl(alice, 10e18);
        assertEq(vault.locked(alice, address(this)), 0);
        vm.expectRevert(abi.encodeWithSelector(E.InsufficientMargin.selector, 0, 5e18));
        vault.release(alice, 5e18);
    }

    function testPartialLoserRefundCannotLeaveRemainingFundingDebt() public {
        vault.lock(alice, 100e18);
        vault.settleFunding(alice, 110e18);
        // A partial ADL at an improved price earns 12 on a portion allocated -5 collateral.
        // Its apparent refund is 7, but the remaining -5 debt leaves only 2 available in total.
        vault.settlePnl(alice, 12e18);
        assertEq(vault.locked(alice, address(this)), 2e18);
        vm.expectRevert(abi.encodeWithSelector(E.InsufficientMargin.selector, 2e18, 7e18));
        vault.release(alice, 7e18);
        assertEq(vault.locked(alice, address(this)), 2e18);
    }

    function testFeesClaimsAndDust() public {
        vm.prank(bob);
        vault.registerReferralCode("BOB");
        vm.prank(alice);
        vault.setReferrer("BOB");
        T.FeeBreakdown memory fee = T.FeeBreakdown(10e18 + 3, 3e18 + 1, 3e18 + 1, 3e18, 1e18 + 1);
        vault.chargeFee(alice, fee, false);
        assertEq(vault.claimCreatorFees(), 3e18);
        assertEq(vault.ledger(address(this)).creatorOwed, 1);
        vault.claimProtocolFees(address(this));
        assertEq(usdc.balanceOf(treasury), 3e6);
        assertEq(vault.ledger(address(this)).protocolOwed, 1);
        vm.prank(bob);
        vault.claimReferral();
        assertEq(usdc.balanceOf(bob), 4e6);
        assertEq(vault.referralOwed(bob), 1);
        assertEq(usdc.balanceOf(address(vault)), 19_993e6);
        fee.total++;
        vm.expectRevert(E.AccountingInvariant.selector);
        vault.chargeFee(alice, fee, false);
    }

    function testReferralBindingIsPermanentAndNotSelf() public {
        vm.startPrank(alice);
        vault.registerReferralCode("ALICE");
        vm.expectRevert(E.InvalidReferral.selector);
        vault.setReferrer("ALICE");
        vm.expectRevert(E.InvalidReferral.selector);
        vault.registerReferralCode("SECOND");
        vm.stopPrank();
        vm.startPrank(bob);
        vault.setReferrer("ALICE");
        vm.expectRevert(E.InvalidReferral.selector);
        vault.setReferrer("ALICE");
        vm.stopPrank();
    }

    function testOperatorLimitsClosePermissionExpiryAndRevocation() public {
        T.OperatorPolicy memory p = T.OperatorPolicy(uint64(block.number + 100), 100e18, 150e18, 99e18, 0, false);
        vm.prank(alice);
        vault.setOperator(operator, p);
        bytes32[] memory proof = new bytes32[](0);
        vm.expectRevert(abi.encodeWithSelector(E.PolicyViolation.selector, 4));
        vault.checkAndConsume(alice, operator, 101e18, false, proof);
        vm.expectRevert(abi.encodeWithSelector(E.PolicyViolation.selector, 2));
        vault.checkAndConsume(alice, operator, 1e18, true, proof);
        vault.checkAndConsume(alice, operator, 100e18, false, proof);
        vm.expectRevert(abi.encodeWithSelector(E.PolicyViolation.selector, 5));
        vault.checkAndConsume(alice, operator, 51e18, false, proof);
        vault.checkAndConsume(alice, operator, 50e18, false, proof);
        vm.prank(alice);
        vault.revokeOperator(operator);
        vm.expectRevert(abi.encodeWithSelector(E.PolicyViolation.selector, 1));
        vault.checkAndConsume(alice, operator, 0, false, proof);
        vm.prank(alice);
        vault.setOperator(operator, p);
        vm.roll(p.expiry);
        vm.expectRevert(abi.encodeWithSelector(E.PolicyViolation.selector, 1));
        vault.checkAndConsume(alice, operator, 1, false, proof);
    }

    function testMerklePolicyAndOnlyMarketConsumption() public {
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(address(this)))));
        bytes32 sibling = keccak256(bytes.concat(keccak256(abi.encode(address(0xdead)))));
        bytes32 root =
            leaf < sibling ? keccak256(abi.encodePacked(leaf, sibling)) : keccak256(abi.encodePacked(sibling, leaf));
        T.OperatorPolicy memory p = T.OperatorPolicy(uint64(block.number + 100), 100e18, 150e18, 0, root, true);
        vm.prank(alice);
        vault.setOperator(operator, p);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = sibling;
        vault.checkAndConsume(alice, operator, 50e18, true, proof);
        vm.expectRevert(abi.encodeWithSelector(E.PolicyViolation.selector, 3));
        vault.checkAndConsume(alice, operator, 1, false, new bytes32[](0));
        vm.prank(operator);
        vm.expectRevert(E.Unauthorized.selector);
        vault.checkAndConsume(alice, operator, 1, false, proof);
    }

    function testDepositCapAndInitializers() public {
        vm.prank(alice);
        vault.deposit(80_000e6);
        usdc.mint(alice, 1);
        vm.prank(alice);
        vm.expectRevert(E.DepositCapExceeded.selector);
        vault.deposit(1);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(address(usdc), alice, alice, alice);
        MarginVault implementation = new MarginVault();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(address(usdc), alice, alice, alice);
    }

    function testUpgradeDelayVetoAuthorizationAndStorage() public {
        MarginVault next = new MarginVault();
        vault.scheduleUpgrade(address(next), keccak256(""));
        vm.expectRevert(E.UpgradeNotReady.selector);
        vault.upgradeToAndCall(address(next), "");
        vm.warp(vault.upgradeReadyAt());
        vm.prank(alice);
        vm.expectRevert(E.Unauthorized.selector);
        vault.upgradeToAndCall(address(next), "");
        vm.prank(guardian);
        vault.cancelUpgrade();
        vm.expectRevert(E.UpgradeNotReady.selector);
        vault.upgradeToAndCall(address(next), "");
        vault.scheduleUpgrade(address(next), keccak256(""));
        vm.warp(vault.upgradeReadyAt());
        vm.expectRevert(E.UpgradeNotReady.selector);
        vault.upgradeToAndCall(address(next), hex"1234");
        vault.upgradeToAndCall(address(next), "");
        assertEq(vault.freeBalance(alice), 10_000e18);
        assertEq(address(vault.token()), address(usdc));
        assertEq(vault.pendingImplementation(), address(0));
    }

    function testTransferHooksCannotReenterWithdrawal() public {
        HookUSDC hook = new HookUSDC();
        MarginVault hookedVault = MarginVault(
            address(
                new ERC1967Proxy(
                    address(new MarginVault()),
                    abi.encodeCall(MarginVault.initialize, (address(hook), address(this), guardian, treasury))
                )
            )
        );
        hook.mint(address(hook), 10e6);
        vm.startPrank(address(hook));
        hook.approve(address(hookedVault), 10e6);
        hookedVault.deposit(10e6);
        vm.stopPrank();
        hook.configure(address(hookedVault), abi.encodeCall(MarginVault.withdraw, (1e6)), false);
        vm.prank(address(hook));
        hookedVault.withdraw(1e6);
        assertFalse(hook.hookSucceeded());
        assertEq(hookedVault.freeBalance(address(hook)), 9e18);
        assertEq(hook.balanceOf(address(hookedVault)), 9e6);
    }

    function testTransferTaxDepositRevertsAtomically() public {
        HookUSDC hook = new HookUSDC();
        MarginVault hookedVault = MarginVault(
            address(
                new ERC1967Proxy(
                    address(new MarginVault()),
                    abi.encodeCall(MarginVault.initialize, (address(hook), address(this), guardian, treasury))
                )
            )
        );
        hook.mint(alice, 10e6);
        hook.configure(address(hookedVault), "", true);
        vm.startPrank(alice);
        hook.approve(address(hookedVault), 10e6);
        vm.expectRevert(E.UnsupportedToken.selector);
        hookedVault.deposit(10e6);
        vm.stopPrank();
        assertEq(hook.balanceOf(alice), 10e6);
        assertEq(hookedVault.freeBalance(alice), 0);
    }
}
