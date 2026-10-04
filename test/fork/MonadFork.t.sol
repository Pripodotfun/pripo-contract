// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MarginVault} from "../../src/MarginVault.sol";
import {PythAdapter} from "../../src/adapters/PythAdapter.sol";
import {IPripoErrors as E} from "../../src/interfaces/IPripoErrors.sol";
import {IPythPriceFeed} from "../../src/interfaces/IPythPriceFeed.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Real Monad contract reads and local native-USDC custody. No transaction is broadcast.
contract MonadForkTest is Test {
    IPythPriceFeed private upgraded;
    IPythPriceFeed private legacy;
    IERC20Metadata private usdc;
    string private config;
    string private preflight;

    function setUp() public {
        vm.skip(!vm.envOr("MONAD_FORK_ENABLED", false), "Enable via scripts/run_monad_fork.py");
        preflight = vm.readFile("reports/monad/preflight.json");
        uint256 pinnedBlock = vm.parseJsonUint(preflight, ".forkBlock");
        assertEq(pinnedBlock, vm.envUint("MONAD_FORK_BLOCK"));
        vm.createSelectFork("monad", pinnedBlock);
        assertEq(block.chainid, 143);
        assertEq(block.number, pinnedBlock);
        assertEq(block.timestamp, vm.parseJsonUint(preflight, ".forkTimestamp"));
        config = vm.readFile("config/monad-mainnet.json");
        upgraded = IPythPriceFeed(vm.parseJsonAddress(config, ".pythCore"));
        legacy = IPythPriceFeed(vm.parseJsonAddress(config, ".legacyPythCore"));
        usdc = IERC20Metadata(vm.parseJsonAddress(config, ".usdc"));
    }

    function testPinnedContractsAndNativeUsdcMetadata() public view {
        assertGt(address(upgraded).code.length, 0);
        assertGt(address(legacy).code.length, 0);
        assertGt(address(usdc).code.length, 0);
        assertEq(usdc.decimals(), 6);
        assertEq(usdc.symbol(), "USDC");
        assertEq(usdc.name(), "USDC");
    }

    function testLegacyCachedEquitiesKeepRealAgeAndConfidence() public {
        PythAdapter adapter = new PythAdapter(legacy, 3, 300);
        string[5] memory tickers = ["NVDA", "TSLA", "AAPL", "COIN", "HOOD"];
        for (uint256 i; i < tickers.length; ++i) {
            bytes32 feed = vm.parseJsonBytes32(config, string.concat(".equityCandidates.", tickers[i], ".us"));
            IPythPriceFeed.Price memory p = legacy.getPriceUnsafe(feed);
            assertEq(
                p.publishTime,
                vm.parseJsonUint(
                    preflight, string.concat(".feeds.", tickers[i], ".candidates.us.legacyPythCore.publish_time")
                )
            );
            assertTrue(adapter.isSupported(feed));
            uint256 ageBlocks = Math.ceilDiv((block.timestamp - p.publishTime) * 1000, 300);
            if (ageBlocks > block.number) {
                vm.expectRevert(E.InvalidOracle.selector);
                adapter.getPrice(feed, "");
                continue;
            }
            (uint256 wad, uint64 updatedBlock, uint16 conf, bool externalIndex) = adapter.getPrice(feed, "");
            int256 shift = int256(p.expo) + 18;
            uint256 expected = shift >= 0
                ? uint256(uint64(p.price)) * 10 ** uint256(shift)
                : uint256(uint64(p.price)) / 10 ** uint256(-shift);
            assertEq(wad, expected);
            assertEq(updatedBlock, block.number - ageBlocks);
            assertEq(conf, Math.ceilDiv(uint256(p.conf) * 10_000, uint64(p.price)));
            assertTrue(externalIndex);
            assertEq(block.number - updatedBlock > 100, ageBlocks > 100, "cache read preserves degradation age");
        }
    }

    function testUpgradedCoreInterfaceAndCachedCandidateSnapshot() public {
        PythAdapter adapter = new PythAdapter(upgraded, 3, 300);
        bytes[] memory empty = new bytes[](0);
        assertEq(upgraded.getUpdateFee(empty), 0);
        string[5] memory tickers = ["NVDA", "TSLA", "AAPL", "COIN", "HOOD"];
        for (uint256 i; i < tickers.length; ++i) {
            _checkUpgradedSnapshot(adapter, tickers[i], "us");
            _checkUpgradedSnapshot(adapter, tickers[i], "index");
        }
        // Missing cached prices do not prove a feed is unsupported by authenticated Hermes updates.
    }

    function _checkUpgradedSnapshot(PythAdapter adapter, string memory ticker, string memory kind) private {
        bytes32 feed = vm.parseJsonBytes32(config, string.concat(".equityCandidates.", ticker, ".", kind));
        string memory prefix = string.concat(".feeds.", ticker, ".candidates.", kind, ".pythCore");
        if (vm.keyExistsJson(preflight, string.concat(prefix, ".error"))) {
            assertFalse(adapter.isSupported(feed));
            vm.expectRevert(bytes4(keccak256("PriceFeedNotFound()")));
            adapter.getPrice(feed, "");
        } else {
            assertTrue(adapter.isSupported(feed));
            assertEq(
                upgraded.getPriceUnsafe(feed).publishTime,
                vm.parseJsonUint(preflight, string.concat(prefix, ".publish_time"))
            );
        }
    }

    function testNativeUsdcVaultReserveDepositAndWithdrawal() public {
        address alice = makeAddr("fork-alice");
        MarginVault vault = MarginVault(
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
        // Only test-account balances are seeded locally; token code and all transfers use real USDC.
        deal(address(usdc), address(this), 10_000e6);
        deal(address(usdc), alice, 500e6);
        usdc.approve(address(vault), type(uint256).max);
        vault.fundProtocolReserve(10_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        uint256 beforeGas = gasleft();
        vault.deposit(500e6);
        emit log_named_uint("native USDC vault deposit local gross gas", beforeGas - gasleft());
        assertEq(vault.freeBalance(alice), 500e18);
        beforeGas = gasleft();
        vault.withdraw(500e6);
        emit log_named_uint("native USDC vault withdrawal local gross gas", beforeGas - gasleft());
        vm.stopPrank();
        assertEq(vault.freeBalance(alice), 0);
        assertEq(usdc.balanceOf(alice), 500e6);
        assertEq(usdc.balanceOf(address(vault)), 10_000e6);
        assertEq(vault.protocolReserve(), 10_000e18);
    }
}
