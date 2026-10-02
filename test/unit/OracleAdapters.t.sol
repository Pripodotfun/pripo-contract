// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {NullAdapter} from "../../src/adapters/NullAdapter.sol";
import {PythAdapter} from "../../src/adapters/PythAdapter.sol";
import {IPripoErrors as E} from "../../src/interfaces/IPripoErrors.sol";
import {IPythPriceFeed} from "../../src/interfaces/IPythPriceFeed.sol";
import {MockPyth} from "../helpers/MockPyth.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Test} from "forge-std/Test.sol";

contract OracleAdaptersTest is Test {
    bytes32 private constant FEED = bytes32("NVDA");
    MockPyth private provider;
    PythAdapter private adapter;

    function setUp() public {
        vm.roll(10_000);
        vm.warp(100_000);
        vm.deal(address(this), 1 ether);
        provider = new MockPyth();
        adapter = new PythAdapter(provider, 3, 300);
        provider.set(FEED, IPythPriceFeed.Price(123456789, 1, -8, block.timestamp));
    }

    function testNullAdapterZeroFeedAndNoNativeValue() public {
        NullAdapter source = new NullAdapter();
        (uint256 price, uint64 at, uint16 conf, bool ext) = source.getPrice(0, "");
        assertEq(price, 0);
        assertEq(at, block.number);
        assertEq(conf, 0);
        assertFalse(ext);
        assertTrue(source.isSupported(0));
        assertFalse(source.isSupported(FEED));
        vm.expectRevert(E.InvalidOracle.selector);
        source.getPrice(FEED, "");
        vm.expectRevert(E.InvalidOracle.selector);
        source.getPrice(0, hex"01");
        vm.expectRevert(E.UnexpectedValue.selector);
        source.getPrice{value: 1}(0, "");
    }

    function testScalingConfidenceAndSignedUpdateFee() public {
        (uint256 price,, uint16 conf, bool ext) = adapter.getPrice(FEED, "");
        assertEq(price, 1.23456789e18);
        assertEq(conf, 1);
        assertTrue(ext);
        assertTrue(adapter.isSupported(FEED));
        assertFalse(adapter.isSupported(bytes32("MISSING")));
        bytes memory update = _update(200000000, 2000000, -8, block.timestamp + 1);
        vm.warp(block.timestamp + 1);
        assertEq(adapter.updateFee(update), 1);
        assertEq(adapter.updateFee(""), 0);
        (price,, conf,) = adapter.getPrice{value: 1}(FEED, update);
        assertEq(price, 2e18);
        assertEq(conf, 100);
        assertEq(address(provider).balance, 1);
        assertEq(address(adapter).balance, 0);
        assertEq(provider.updates(), 1);
    }

    function testCachedReadPreservesAgeAndBoundaryRoundsUp() public {
        vm.warp(100_003);
        vm.roll(10_010);
        (, uint64 at,,) = adapter.getPrice(FEED, "");
        assertEq(at, 10_000);
        vm.warp(100_004);
        vm.roll(10_014);
        (, at,,) = adapter.getPrice(FEED, "");
        assertEq(at, 10_000); // ceil(4 / 0.3) == 14, never floor to a younger observation.
        bytes memory staleUpdate = _update(123456789, 1, -8, 100_000);
        vm.expectRevert(MockPyth.StalePrice.selector);
        adapter.getPrice{value: 1}(FEED, staleUpdate);
        assertEq(provider.updates(), 0);
        assertEq(address(adapter).balance, 0);
        vm.roll(1);
        vm.expectRevert(E.InvalidOracle.selector);
        adapter.getPrice(FEED, "");
    }

    function testRejectFeesMalformedUpdatesAndRecursiveOracleCall() public {
        vm.expectRevert(E.UnexpectedValue.selector);
        adapter.getPrice{value: 1}(FEED, "");
        bytes memory update = _update(100, 0, 0, block.timestamp);
        vm.expectRevert(E.UnexpectedValue.selector);
        adapter.getPrice(FEED, update);
        vm.expectRevert(E.UnexpectedValue.selector);
        adapter.getPrice{value: 2}(FEED, update);
        vm.expectRevert();
        adapter.getPrice(FEED, hex"01");
        vm.expectRevert(E.InvalidOracle.selector);
        adapter.getPrice(FEED, abi.encode(new bytes[](0)));
        provider.setCallback(address(adapter), abi.encodeCall(PythAdapter.getPrice, (FEED, "")));
        adapter.getPrice{value: 1}(FEED, update);
        assertFalse(provider.callbackSucceeded());
        assertEq(
            provider.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
    }

    function testInvalidPricesExponentBoundsAndConfidenceSaturation() public {
        _reject(0, -8, block.timestamp);
        _reject(-1, -8, block.timestamp);
        _reject(1, -37, block.timestamp);
        _reject(1, 11, block.timestamp);
        _reject(1, -19, block.timestamp); // A positive feed below one quote wei cannot seed a market.
        _reject(1, -8, block.timestamp + 1);
        provider.set(FEED, IPythPriceFeed.Price(1, type(uint64).max, 10, block.timestamp));
        (uint256 price,, uint16 conf,) = adapter.getPrice(FEED, "");
        assertEq(price, 1e28);
        assertEq(conf, type(uint16).max);
        provider.set(FEED, IPythPriceFeed.Price(2, 0, 10, block.timestamp));
        vm.expectRevert(E.InvalidOracle.selector);
        adapter.getPrice(FEED, "");
        provider.set(FEED, IPythPriceFeed.Price(1234567890123456789, 0, -20, block.timestamp));
        (price,,,) = adapter.getPrice(FEED, "");
        assertEq(price, 12345678901234567);
    }

    function testFuzzConfidenceNeverRoundsBelowReportedWidth(uint64 rawSeed, uint64 confidence) public {
        int64 raw = int64(uint64(bound(rawSeed, 1, 1e18)));
        provider.set(FEED, IPythPriceFeed.Price(raw, confidence, -8, block.timestamp));
        (uint256 price,, uint16 bps,) = adapter.getPrice(FEED, "");
        assertEq(price, uint256(uint64(raw)) * 1e10);
        uint256 numerator = uint256(confidence) * 10_000;
        if (numerator > uint256(type(uint16).max) * uint64(raw)) {
            assertEq(bps, type(uint16).max);
        } else {
            assertGe(uint256(bps) * uint64(raw), numerator);
            if (bps > 0) assertLt(uint256(bps - 1) * uint64(raw), numerator);
        }
    }

    function testConstructorRejectsMissingProviderAndZeroTimingParameters() public {
        vm.expectRevert(E.InvalidAddress.selector);
        new PythAdapter(IPythPriceFeed(address(0)), 3, 300);
        vm.expectRevert(E.InvalidConfiguration.selector);
        new PythAdapter(provider, 0, 300);
        vm.expectRevert(E.InvalidConfiguration.selector);
        new PythAdapter(provider, 3, 0);
    }

    function _reject(int64 raw, int32 expo, uint256 at) private {
        provider.set(FEED, IPythPriceFeed.Price(raw, 0, expo, at));
        vm.expectRevert(E.InvalidOracle.selector);
        adapter.getPrice(FEED, "");
    }

    function _update(int64 price, uint64 conf, int32 expo, uint256 at) private pure returns (bytes memory) {
        bytes[] memory payload = new bytes[](1);
        payload[0] = abi.encode(FEED, IPythPriceFeed.Price(price, conf, expo, at));
        return abi.encode(payload);
    }
}
