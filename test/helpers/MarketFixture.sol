// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MarginVault} from "../../src/MarginVault.sol";
import {Market} from "../../src/Market.sol";
import {IMarginVault} from "../../src/interfaces/IMarginVault.sol";
import {IPriceSource} from "../../src/interfaces/IPriceSource.sol";
import {RiskMath} from "../../src/libraries/RiskMath.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {MockUSDC} from "./MockUSDC.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

contract MockPriceSource is IPriceSource {
    uint256 public price;
    uint64 public updatedBlock;
    uint16 public confidence;
    bool public broken;
    bool public isExternal = true;
    uint256 public calls;
    uint256 public requiredFee;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSucceeded;
    bytes public callbackResult;

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function set(uint256 p, uint64 b, uint16 c) external {
        price = p;
        updatedBlock = b;
        confidence = c;
    }

    function setBroken(bool value) external {
        broken = value;
    }

    function setExternal(bool value) external {
        isExternal = value;
    }

    function setFee(uint256 fee) external {
        requiredFee = fee;
    }

    function getPrice(bytes32, bytes calldata) external payable returns (uint256, uint64, uint16, bool) {
        require(!broken && msg.value == requiredFee, "mock source unavailable");
        calls++;
        if (callbackTarget != address(0)) (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
        return (price, updatedBlock, confidence, isExternal);
    }

    function isSupported(bytes32) external pure returns (bool) {
        return true;
    }
}

abstract contract MarketFixture is Test {
    MarginVault internal vault;
    Market internal market;
    MockUSDC internal usdc;
    MockPriceSource internal source;
    MockPriceSource internal secondary;
    address internal alice = address(0xa11ce);
    address internal bob = address(0xb0b);
    address internal carol = address(0xca201);
    address internal creator = address(0xc2ea);
    address internal guardian = address(0x600d);
    address internal treasury = address(0x700d);

    function _setup(bool externalIndex) internal {
        usdc = new MockUSDC();
        vault = MarginVault(
            address(
                new ERC1967Proxy(
                    address(new MarginVault()),
                    abi.encodeCall(MarginVault.initialize, (address(usdc), address(this), guardian, treasury))
                )
            )
        );
        usdc.mint(address(this), 10_000e6);
        usdc.approve(address(vault), type(uint256).max);
        vault.fundProtocolReserve(10_000e6);
        _deposit(creator, 20_000e6);
        _deposit(alice, 10_000e6);
        _deposit(bob, 10_000e6);
        _deposit(carol, 10_000e6);
        source = new MockPriceSource();
        secondary = new MockPriceSource();
        source.set(100e18, uint64(block.number), 0);
        secondary.set(100e18, uint64(block.number), 0);
        market = _newMarket(externalIndex);
    }

    function _newMarket(bool externalIndex) internal returns (Market deployed) {
        deployed = Market(Clones.clone(_marketImplementation()));
        vault.registerMarket(address(deployed), creator);
        vm.prank(creator);
        vault.fundInsurance(address(deployed), externalIndex ? 5_000e18 : 2_000e18);
        deployed.initialize(
            IMarginVault(address(vault)), bytes32("TEST"), externalIndex, _config(externalIndex), 100e18, 2_000_000e18
        );
    }

    function _marketImplementation() internal virtual returns (address) {
        return address(new Market());
    }

    function _config(bool externalIndex) internal view virtual returns (T.MarketConfig memory c) {
        c.priceSource = externalIndex ? address(source) : address(0);
        c.creator = creator;
        c.takerFeeBps = 8;
        c.creatorShareBps = 3000;
        c.insuranceShareBps = 3000;
        c.referralShareBps = 1000;
        c.maxLeverageX = externalIndex ? 5 : 2;
        c.mmrBps = externalIndex ? 250 : 1500;
        c.liqPenaltyBps = 150;
        c.receiveCapX = 10;
        c.sideCapBps = RiskMath.sideCapBps(c.maxLeverageX);
        c.impactMarginBps = 10_000;
        c.maxOracleAgeBlocks = 10;
        c.degradeAfterBlocks = 100;
        c.degradedTwapBlocks = 600;
        c.fundingCapPerBlock = uint64((externalIndex ? uint256(0.001e18) : uint256(0.005e18)) / 12_000);
    }

    function _deposit(address user, uint256 raw) internal {
        usdc.mint(user, raw);
        vm.startPrank(user);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(raw);
        vm.stopPrank();
    }

    function _open(address user, int256 size) internal {
        vm.prank(user);
        market.open(size, size > 0 ? type(uint256).max : 0, "");
    }

    function _close(address user, uint256 fraction) internal {
        int256 size = market.position(user).size;
        vm.prank(user);
        market.close(fraction, size > 0 ? 0 : type(uint256).max, "");
    }

    function _assertCash() internal view {
        T.Ledger memory l = vault.ledger(address(market));
        int256 sum = int256(
            vault.freeBalance(alice) + vault.freeBalance(bob) + vault.freeBalance(carol) + vault.freeBalance(creator)
                + vault.backstopBalance() + vault.protocolReserve()
        );
        sum += vault.locked(alice, address(market)) + vault.locked(bob, address(market))
        + vault.locked(carol, address(market)) + vault.locked(creator, address(market));
        sum += int256(l.insurance + l.protocolOwed + l.creatorOwed + l.skewPool + vault.referralOwed(creator));
        sum += l.clearing + l.fundingPool;
        sum -= int256(vault.totalDeficit());
        assertEq(sum, int256(usdc.balanceOf(address(vault)) * 1e12), "cash equality");
        T.AmmState memory a = market.ammState();
        assertEq(l.clearing, int256(a.quoteReserve) - int256(a.curveBase) - a.entryCostNet, "curve conservation");
        assertEq(int256(market.longSize()) - int256(market.shortSize()), int256(a.baseAtSeed) - int256(a.baseReserve));
    }
}
