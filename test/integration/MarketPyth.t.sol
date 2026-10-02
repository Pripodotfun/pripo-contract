// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PythAdapter} from "../../src/adapters/PythAdapter.sol";
import {IPripoErrors as E} from "../../src/interfaces/IPripoErrors.sol";
import {IPythPriceFeed} from "../../src/interfaces/IPythPriceFeed.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {MarketFixture} from "../helpers/MarketFixture.sol";
import {MockPyth} from "../helpers/MockPyth.sol";

contract MarketPythTest is MarketFixture {
    MockPyth private provider;
    PythAdapter private adapter;

    function setUp() public {
        vm.roll(1000);
        vm.warp(100_000);
        provider = new MockPyth();
        adapter = new PythAdapter(provider, 3, 300);
        provider.set(bytes32("TEST"), IPythPriceFeed.Price(100e8, 0, -8, block.timestamp));
        _setup(true);
    }

    function _config(bool externalIndex) internal view override returns (T.MarketConfig memory c) {
        c = super._config(externalIndex);
        c.priceSource = address(adapter);
    }

    function testPullUpdateThenStaleCloseDegradeAndRecover() public {
        vm.roll(1004);
        vm.warp(100_001);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        market.open{value: 1}(5e18, type(uint256).max, _update(101e8, 0, 100_001));
        assertEq(address(adapter).balance, 0);
        assertEq(address(market).balance, 0);
        assertEq(address(provider).balance, 1);
        vm.roll(1018);
        vm.warp(100_005);
        vm.prank(bob);
        vm.expectPartialRevert(E.StaleOracle.selector);
        market.open(-1e18, 0, "");
        _close(alice, 0.5e18); // Closing does not call even a stale source.
        vm.roll(1110);
        vm.warp(100_035);
        market.poke();
        (uint8 state,) = market.status();
        assertEq(state, uint8(T.Status.Degraded));
        assertEq(market.fundingRatePerBlock(), 0);
        vm.deal(address(this), 1 ether);
        market.remark{value: 1}(_update(102e8, 0, 100_035));
        (state,) = market.status();
        assertEq(state, uint8(T.Status.Active));
        _assertCash();
    }

    function testConfidenceCeilingCannotSneakAboveOnePercentThroughFloorRounding() public {
        provider.set(bytes32("TEST"), IPythPriceFeed.Price(100e8, 100000001, -8, block.timestamp));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(E.OracleConfidence.selector, uint16(101)));
        market.open(1e18, type(uint256).max, "");
        provider.set(bytes32("TEST"), IPythPriceFeed.Price(100e8, 100000000, -8, block.timestamp));
        _open(alice, 1e18);
        _assertCash();
    }

    function _update(int64 price, uint64 conf, uint256 at) private pure returns (bytes memory) {
        bytes[] memory payload = new bytes[](1);
        payload[0] = abi.encode(bytes32("TEST"), IPythPriceFeed.Price(price, conf, -8, at));
        return abi.encode(payload);
    }
}
