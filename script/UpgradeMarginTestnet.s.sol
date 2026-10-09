// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Market} from "../src/Market.sol";
import {FundingMath} from "../src/libraries/FundingMath.sol";
import {MarkTwap} from "../src/libraries/MarkTwap.sol";
import {MarketAccounting} from "../src/market/MarketAccounting.sol";
import {MarketAdl} from "../src/market/MarketAdl.sol";
import {MarketFundingCapacity} from "../src/market/MarketFundingCapacity.sol";
import {MarketLens} from "../src/market/MarketLens.sol";
import {MarketLiquidation} from "../src/market/MarketLiquidation.sol";
import {MarketMaintenance} from "../src/market/MarketMaintenance.sol";
import {MarketMargin} from "../src/market/MarketMargin.sol";
import {MarketSettlement} from "../src/market/MarketSettlement.sol";
import {MarketTrading} from "../src/market/MarketTrading.sol";
import {PripoTypes as T} from "../src/types/PripoTypes.sol";
import {TestnetDeployment} from "./DeployTestnet.s.sol";

/// @notice Deploy only the new implementation and its fixed linked modules, preserving existing custody and markets.
contract DeployMarginImplementation is TestnetDeployment {
    function run() external returns (Market implementation) {
        require(block.chainid == 10143, "testnet only");
        (Config memory c, Deployment memory d) = _readManifest();
        _verify(c, d);
        address sender = _signer();
        require(sender == d.vault.governor(), "wrong governor");
        require(d.factory.pendingImplementation() == address(0), "upgrade already pending");
        vm.startBroadcast(sender);
        implementation = new Market();
        vm.stopBroadcast();
        require(implementation.marginEntryVersion() == 1, "wrong capability");

        address[] memory contracts = new address[](12);
        contracts[0] = address(implementation);
        contracts[1] = address(FundingMath);
        contracts[2] = address(MarkTwap);
        contracts[3] = address(MarketFundingCapacity);
        contracts[4] = address(MarketAccounting);
        contracts[5] = address(MarketLens);
        contracts[6] = address(MarketSettlement);
        contracts[7] = address(MarketAdl);
        contracts[8] = address(MarketTrading);
        contracts[9] = address(MarketLiquidation);
        contracts[10] = address(MarketMargin);
        contracts[11] = address(MarketMaintenance);
        bytes32[] memory hashes = new bytes32[](contracts.length);
        for (uint256 i; i < contracts.length; ++i) {
            require(contracts[i].code.length != 0, "missing module");
            hashes[i] = contracts[i].codehash;
        }
        string memory key = "margin-implementation";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeBool(key, "mockCollateral", true);
        vm.serializeAddress(key, "factory", address(d.factory));
        vm.serializeAddress(key, "vault", address(d.vault));
        vm.serializeAddress(key, "deployer", sender);
        vm.serializeAddress(key, "previousImplementation", address(d.market));
        vm.serializeAddress(key, "implementation", address(implementation));
        vm.serializeAddress(key, "contracts", contracts);
        string memory json = vm.serializeBytes32(key, "runtimeCodeHashes", hashes);
        vm.writeJson(json, vm.envString("MARGIN_OUTPUT"));
    }
}

/// @notice Each entry point is a separately journaled stage. No delay override exists on public testnet.
contract ConfigureMarginImplementation is TestnetDeployment {
    string public constant SYMBOL = "PRIPO:DEMO-V2";

    function _context() internal view returns (Config memory c, Deployment memory d, address implementation) {
        require(block.chainid == 10143, "testnet only");
        (c, d) = _readManifest();
        string memory json = vm.readFile(vm.envString("MARGIN_OUTPUT"));
        require(vm.parseJsonUint(json, ".chainId") == 10143, "wrong upgrade chain");
        require(vm.parseJsonAddress(json, ".factory") == address(d.factory), "wrong upgrade factory");
        require(vm.parseJsonAddress(json, ".vault") == address(d.vault), "wrong upgrade vault");
        require(
            vm.parseJsonAddress(json, ".previousImplementation") == address(d.market), "wrong previous implementation"
        );
        implementation = vm.parseJsonAddress(json, ".implementation");
        address[] memory contracts = vm.parseJsonAddressArray(json, ".contracts");
        bytes32[] memory hashes = vm.parseJsonBytes32Array(json, ".runtimeCodeHashes");
        require(contracts.length == 12 && hashes.length == 12 && contracts[0] == implementation, "incomplete upgrade");
        for (uint256 i; i < contracts.length; ++i) {
            require(contracts[i].code.length != 0 && contracts[i].codehash == hashes[i], "upgrade runtime mismatch");
        }
        require(Market(implementation).marginEntryVersion() == 1, "missing margin entry");
        Market previous = d.market;
        d.market = Market(d.factory.marketImplementation());
        _verify(c, d);
        d.market = previous;
        require(d.vault.registrars(address(d.factory)), "factory disabled");
    }

    function schedule() external {
        (Config memory c, Deployment memory d, address implementation) = _context();
        address sender = _signer();
        require(sender == c.governor, "wrong governor");
        require(d.factory.marketImplementation() == address(d.market), "implementation changed");
        require(d.factory.pendingImplementation() == address(0), "upgrade already pending");
        vm.startBroadcast(sender);
        d.factory.scheduleImplementation(implementation);
        vm.stopBroadcast();
        require(d.factory.pendingImplementation() == implementation, "schedule mismatch");
    }

    function activate() external {
        (, Deployment memory d, address implementation) = _context();
        require(d.factory.marketImplementation() == address(d.market), "implementation changed");
        require(d.factory.pendingImplementation() == implementation, "wrong pending implementation");
        require(
            d.factory.implementationReadyAt() != 0 && block.timestamp >= d.factory.implementationReadyAt(),
            "delay not elapsed"
        );
        vm.startBroadcast(_signer());
        d.factory.activateImplementation();
        vm.stopBroadcast();
        require(d.factory.marketImplementation() == implementation, "activation mismatch");
    }

    function create() external returns (Market market) {
        (, Deployment memory d, address implementation) = _context();
        require(d.factory.marketImplementation() == implementation, "activate implementation first");
        require(d.factory.pendingImplementation() == address(0), "another upgrade pending");
        require(d.factory.marketForSymbol(keccak256(bytes(SYMBOL))) == address(0), "market already exists");
        address sender = _signer();
        uint256 reserve = d.vault.protocolReserve();
        uint256 cash = d.vault.token().balanceOf(address(d.vault));
        uint256 balance = d.vault.token().balanceOf(sender);
        require(balance >= 2_000e6, "seed balance too low");
        address predicted = d.factory.predictAddress(SYMBOL);
        T.CreateParams memory params =
            T.CreateParams(SYMBOL, address(d.nullAdapter), bytes32(0), 100e18, 200_000e18, 2_000e6);
        vm.startBroadcast(sender);
        require(d.vault.token().approve(address(d.factory), 2_000e6), "approval failed");
        market = Market(d.factory.createMarket(params));
        vm.stopBroadcast();
        require(address(market) == predicted && d.factory.isMarket(predicted), "creation mismatch");
        require(market.marginEntryVersion() == 1 && address(market.vault()) == address(d.vault), "wrong market");
        require(market.markPrice() == 100e18 && market.positionCount() == 0, "wrong initial market state");
        require(d.vault.ledger(predicted).insurance == 2_000e18, "wrong insurance");
        require(d.vault.protocolReserve() == reserve, "reserve changed");
        require(d.vault.token().balanceOf(address(d.vault)) == cash + 2_000e6, "seed not backed");
        require(d.vault.token().balanceOf(sender) == balance - 2_000e6, "wrong seed debit");
        require(d.vault.token().allowance(sender, address(d.factory)) == 0, "unused approval");
        d.vault.requireOpenAllowed(predicted);
        string memory key = "margin-market";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeString(key, "symbol", SYMBOL);
        vm.serializeAddress(key, "factory", address(d.factory));
        vm.serializeAddress(key, "implementation", implementation);
        vm.serializeAddress(key, "market", predicted);
        string memory json = vm.serializeBytes32(key, "runtimeCodeHash", predicted.codehash);
        vm.writeJson(json, vm.envString("MARGIN_MARKET_OUTPUT"));
    }
}
