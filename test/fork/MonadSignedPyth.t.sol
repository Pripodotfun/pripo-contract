// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PythAdapter} from "../../src/adapters/PythAdapter.sol";
import {IPripoErrors as E} from "../../src/interfaces/IPripoErrors.sol";
import {IPythPriceFeed} from "../../src/interfaces/IPythPriceFeed.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Authenticated Hermes payloads verified by the actual Monad provider in a local fork.
abstract contract MonadSignedPythFixture is Test {
    IPythPriceFeed internal provider;
    PythAdapter internal adapter;
    string internal report;
    string internal config;
    bytes32 internal feed;
    bytes[] internal updates;
    uint256 internal fee;
    IPythPriceFeed.Price internal signedPrice;

    function setUp() public virtual {
        vm.skip(!vm.envOr("MONAD_FORK_ENABLED", false), "Enable via scripts/run_monad_fork.py");
        report = vm.readFile("reports/monad/preflight.json");
        vm.skip(!vm.keyExistsJson(report, ".controlUpdate.updates.binary"), "Capture an entitled signed control update");
        vm.createSelectFork("monad", vm.parseJsonUint(report, ".updateFork.block"));
        assertEq(block.chainid, 143);
        assertEq(block.timestamp, vm.parseJsonUint(report, ".updateFork.timestamp"));
        config = vm.readFile("config/monad-mainnet.json");
        provider = IPythPriceFeed(vm.parseJsonAddress(config, ".pythCore"));
        adapter = new PythAdapter(provider, 3, 300);
        feed = vm.parseJsonBytes32(config, ".controlFeed.feedId");
        updates = _updates(".controlUpdate.updates");
        signedPrice = _price(".controlUpdate.updates.parsed[0].price");
        assertEq(
            vm.parseBytes32(string.concat("0x", vm.parseJsonString(report, ".controlUpdate.updates.parsed[0].id"))),
            feed
        );
        assertLe(signedPrice.publishTime, block.timestamp, "no backdated fork or future observation");
        fee = provider.getUpdateFee(updates);
        vm.deal(address(this), 1 ether);
    }

    function _updates(string memory prefix) internal view returns (bytes[] memory result) {
        assertEq(vm.parseJsonString(report, string.concat(prefix, ".binary.encoding")), "hex");
        string[] memory encoded = vm.parseJsonStringArray(report, string.concat(prefix, ".binary.data"));
        result = new bytes[](encoded.length);
        for (uint256 i; i < encoded.length; ++i) {
            result[i] = vm.parseBytes(string.concat("0x", encoded[i]));
        }
        assertGt(result.length, 0);
    }

    function _price(string memory prefix) internal view returns (IPythPriceFeed.Price memory p) {
        p.price = int64(vm.parseInt(vm.parseJsonString(report, string.concat(prefix, ".price"))));
        p.conf = uint64(vm.parseUint(vm.parseJsonString(report, string.concat(prefix, ".conf"))));
        p.expo = int32(vm.parseJsonInt(report, string.concat(prefix, ".expo")));
        p.publishTime = vm.parseJsonUint(report, string.concat(prefix, ".publish_time"));
    }

    function _assertPrice(IPythPriceFeed.Price memory actual, IPythPriceFeed.Price memory expected) internal pure {
        assertEq(actual.price, expected.price);
        assertEq(actual.conf, expected.conf);
        assertEq(actual.expo, expected.expo);
        assertEq(actual.publishTime, expected.publishTime);
    }
}

contract MonadSignedPythTest is MonadSignedPythFixture {
    function testSignedControlUpdateThroughProductionAdapter() public {
        bytes memory payload = abi.encode(updates);
        assertEq(adapter.updateFee(payload), fee);
        uint256 beforeBalance = address(this).balance;
        uint256 gasBefore = gasleft();
        (uint256 wad, uint64 atBlock, uint16 confidence, bool externalIndex) =
            adapter.getPrice{value: fee}(feed, payload);
        emit log_named_uint("signed BTC adapter update local gross gas", gasBefore - gasleft());
        emit log_named_uint("provider update fee in native wei", fee);
        IPythPriceFeed.Price memory p = provider.getPriceUnsafe(feed);
        assertGe(p.publishTime, signedPrice.publishTime);
        if (p.publishTime == signedPrice.publishTime) _assertPrice(p, signedPrice);
        assertEq(p.expo, -8);
        assertEq(wad, uint256(uint64(p.price)) * 1e10);
        assertEq(confidence, Math.ceilDiv(uint256(p.conf) * 10_000, uint64(p.price)));
        assertEq(atBlock, block.number - Math.ceilDiv((block.timestamp - p.publishTime) * 1000, 300));
        assertTrue(externalIndex);
        assertEq(address(adapter).balance, 0);
        assertEq(address(this).balance, beforeBalance - fee);
    }

    function testTamperedPayloadAndIncorrectFeeAreRejected() public {
        vm.expectRevert(E.UnexpectedValue.selector);
        adapter.getPrice{value: fee + 1}(feed, abi.encode(updates));
        if (fee != 0) {
            vm.expectRevert(E.UnexpectedValue.selector);
            adapter.getPrice{value: fee - 1}(feed, abi.encode(updates));
        }
        bytes[] memory corrupt = updates;
        uint256 end = corrupt[0].length - 1;
        corrupt[0][end] = bytes1(uint8(corrupt[0][end]) ^ 1);
        vm.expectRevert();
        adapter.getPrice{value: fee}(feed, abi.encode(corrupt));
        assertEq(address(adapter).balance, 0);
    }

    function testReplayingOldSignedDataCannotRefreshItsTimestamp() public {
        bytes memory payload = abi.encode(updates);
        adapter.getPrice{value: fee}(feed, payload);
        uint256 published = provider.getPriceUnsafe(feed).publishTime;
        vm.warp(block.timestamp + 4);
        vm.roll(block.number + 14);
        vm.expectRevert(bytes4(keccak256("StalePrice()")));
        adapter.getPrice{value: fee}(feed, payload);
        assertEq(provider.getPriceUnsafe(feed).publishTime, published);
        (, uint64 atBlock,,) = adapter.getPrice(feed, "");
        assertGt(block.number - atBlock, 10);
    }

    function testEntitledEquitySignaturesPreserveWeekendStaleness() public {
        string[5] memory tickers = ["NVDA", "TSLA", "AAPL", "COIN", "HOOD"];
        uint256 verified;
        for (uint256 i; i < tickers.length; ++i) {
            bytes32 equity = vm.parseJsonBytes32(config, string.concat(".equityCandidates.", tickers[i], ".us"));
            string memory prefix = string.concat(".equityUpdates.", vm.toString(equity), ".updates");
            if (!vm.keyExistsJson(report, string.concat(prefix, ".binary"))) continue;
            bytes[] memory data = _updates(prefix);
            IPythPriceFeed.Price memory expected = _price(string.concat(prefix, ".parsed[0].price"));
            uint256 value = provider.getUpdateFee(data);
            uint256 gasBefore = gasleft();
            provider.updatePriceFeeds{value: value}(data);
            emit log_named_uint(
                string.concat(tickers[i], " signed provider update local gross gas"), gasBefore - gasleft()
            );
            IPythPriceFeed.Price memory actual = provider.getPriceUnsafe(equity);
            assertGe(actual.publishTime, expected.publishTime);
            if (actual.publishTime == expected.publishTime) _assertPrice(actual, expected);
            if (block.timestamp > actual.publishTime + 3) {
                vm.expectRevert(bytes4(keccak256("StalePrice()")));
                adapter.getPrice{value: value}(equity, abi.encode(data));
            } else {
                adapter.getPrice{value: value}(equity, abi.encode(data));
            }
            ++verified;
        }
        vm.skip(verified == 0, "No entitled regular equity payload was captured");
        emit log_named_uint("regular equity signatures verified", verified);
    }
}
