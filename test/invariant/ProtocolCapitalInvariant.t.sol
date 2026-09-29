// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MarginVault} from "../../src/MarginVault.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {MockUSDC} from "../helpers/MockUSDC.sol";
import {TerminalMarketStub} from "../helpers/TerminalMarketStub.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

contract ProtocolCapitalHandler is Test {
    MarginVault internal vault;
    MockUSDC internal usdc;
    address[8] internal markets;
    address internal user;
    uint256 public paidTreasury;

    constructor(MarginVault vault_, MockUSDC usdc_, address[8] memory markets_, address user_) {
        vault = vault_;
        usdc = usdc_;
        markets = markets_;
        user = user_;
        usdc.approve(address(vault), type(uint256).max);
    }

    function fees(uint8 index, uint64 seed) external {
        address market = markets[index % 8];
        if (vault.terminalFinalized(market)) return;
        uint256 available = vault.freeBalance(user);
        if (available == 0) return;
        uint256 amount = bound(seed, 1, available < 500e18 ? available : 500e18);
        uint256 protocol = amount / 2;
        uint256 creator = amount / 4;
        vm.prank(market);
        vault.chargeFee(user, T.FeeBreakdown(amount, protocol, creator, amount - protocol - creator, 0), false);
    }

    function terminal(uint8 index, uint96 seed) external {
        address market = markets[index % 8];
        if (vault.terminalFinalized(market)) return;
        uint256 debt = bound(seed, 0, 20_000e18);
        vm.prank(market);
        vault.settleFunding(user, int256(debt));
        TerminalMarketStub(market).setState(T.Status.Settled, 0, 0);
        address[] memory debtors = new address[](1);
        debtors[0] = user;
        vm.prank(market);
        vault.finalizeSettlement(debtors);
    }

    function fund(uint64 seed) external {
        uint256 raw = bound(seed, 1, 3_000e6);
        usdc.mint(address(this), raw);
        vault.fundProtocolReserve(raw);
    }

    function recap(uint8 index, uint64 seed) external {
        address market = markets[index % 8];
        if (vault.deficit(market) == 0) return;
        uint256 raw = bound(seed, 1, 3_000e6);
        usdc.mint(address(this), raw);
        vault.recapitalize(market, raw);
    }

    function donate(uint8 index, uint96 seed) external {
        address market = markets[index % 8];
        uint256 available = vault.freeBalance(user);
        uint256 debt = vault.deficit(market);
        uint256 cap = available < debt ? available : debt;
        if (cap == 0) return;
        uint256 amount = bound(seed, 1, cap);
        vm.prank(user);
        vault.contributeToDeficit(market, amount);
    }

    function allocate(uint8 index, uint8 count) external {
        vault.allocateProtocolFees(markets[index % 8], uint256(count % 8) + 1);
    }

    function sweep(uint8 index) external {
        if (vault.totalDeficit() != 0 || vault.protocolReserve() < vault.reserveFloor()) return;
        paidTreasury += vault.claimProtocolFees(markets[index % 8]) / 1e12;
        assertEq(vault.totalDeficit(), 0);
        assertGe(vault.protocolReserve(), vault.reserveFloor(), "reserve floor after every sweep");
    }

    function advance(uint8 seconds_) external {
        vm.warp(vm.getBlockTimestamp() + seconds_);
    }
}

contract ProtocolCapitalInvariantTest is StdInvariant, Test {
    MarginVault internal vault;
    MockUSDC internal usdc;
    ProtocolCapitalHandler internal handler;
    address[8] internal markets;
    address internal user = address(0xa11ce);
    address internal treasury = address(0x777);

    function setUp() public {
        usdc = new MockUSDC();
        vault = MarginVault(
            address(
                new ERC1967Proxy(
                    address(new MarginVault()),
                    abi.encodeCall(MarginVault.initialize, (address(usdc), address(this), address(this), treasury))
                )
            )
        );
        usdc.mint(address(this), 10_000e6);
        usdc.approve(address(vault), type(uint256).max);
        vault.fundProtocolReserve(10_000e6);
        usdc.mint(user, 30_000e6);
        vm.startPrank(user);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(30_000e6);
        vm.stopPrank();
        for (uint256 i; i < 8; ++i) {
            markets[i] = address(new TerminalMarketStub());
            vault.registerMarket(markets[i], user);
            vm.prank(markets[i]);
            vault.admitMarket(25_000e18, uint64(uint256(0.005e18) / 12_000));
        }
        handler = new ProtocolCapitalHandler(vault, usdc, markets, user);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.fees.selector;
        selectors[1] = handler.terminal.selector;
        selectors[2] = handler.fund.selector;
        selectors[3] = handler.recap.selector;
        selectors[4] = handler.donate.selector;
        selectors[5] = handler.allocate.selector;
        selectors[6] = handler.sweep.selector;
        selectors[7] = handler.advance.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_CashDebtTerminalStateAndAdmissionBudget() public view {
        int256 cash = int256(vault.freeBalance(user) + vault.protocolReserve() + vault.backstopBalance());
        uint256 total;
        uint256 budget;
        address expectedHead;
        uint256 oldest = type(uint256).max;
        for (uint256 i; i < 8; ++i) {
            address m = markets[i];
            T.Ledger memory l = vault.ledger(m);
            uint256 debt = vault.deficit(m);
            total += debt;
            budget += vault.reserveBudget(m);
            cash += int256(l.insurance + l.creatorOwed + l.protocolOwed + l.skewPool) + l.clearing + l.fundingPool
            + vault.locked(user, m) - int256(debt);
            if (debt != 0) {
                (uint8 state,) = TerminalMarketStub(m).status();
                assertEq(state, uint8(T.Status.Settled));
                assertTrue(vault.terminalFinalized(m));
                assertEq(vault.reserveBudget(m), 0);
                uint256 created = vault.deficitCreatedAt(m);
                if (created < oldest || (created == oldest && m < expectedHead)) {
                    oldest = created;
                    expectedHead = m;
                }
            }
        }
        assertEq(cash, int256(usdc.balanceOf(address(vault)) * 1e12), "actual token cash identity");
        assertEq(vault.totalDeficit(), total);
        assertEq(vault.aggregateReserveBudget(), budget);
        assertEq(vault.reserveFloor(), budget > 10_000e18 ? budget : 10_000e18);
        assertEq(usdc.balanceOf(treasury), handler.paidTreasury());
        (address head,) = vault.deficitQueueHead();
        if (head != address(0) && vault.deficit(head) != 0) assertEq(head, expectedHead, "oldest priority");
    }
}
