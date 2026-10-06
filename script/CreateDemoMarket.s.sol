// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Market} from "../src/Market.sol";
import {PripoTypes as T} from "../src/types/PripoTypes.sol";
import {TestnetDeployment} from "./DeployTestnet.s.sol";

/// @notice Create the first clearly labelled oracle-less market using the funded mock testnet vault.
contract CreateDemoMarket is TestnetDeployment {
    string public constant SYMBOL = "PRIPO:DEMO";
    uint256 public constant INITIAL_PRICE = 100e18;
    uint256 public constant DEPTH = 200_000e18;
    uint256 public constant SEED_BOND = 2_000e6;

    function run() external returns (Market market) {
        require(block.chainid == 10143, "testnet only");
        string memory source = vm.readFile(vm.envString("DEPLOY_OUTPUT"));
        require(vm.parseJsonBool(source, ".mockCollateral"), "mock collateral required");
        (Config memory c, Deployment memory d) = _readManifest();
        _verify(c, d);
        require(c.usdc.codehash == vm.parseJsonBytes32(source, ".mockTokenCodeHash"), "wrong mock token");
        address sender = _signer();
        require(d.factory.marketForSymbol(keccak256(bytes(SYMBOL))) == address(0), "demo already created");
        uint256 count = d.factory.marketCount();
        uint256 reserve = d.vault.protocolReserve();
        uint256 cash = d.vault.token().balanceOf(address(d.vault));
        uint256 balance = d.vault.token().balanceOf(sender);
        require(reserve >= d.vault.reserveFloor(), "reserve not funded");
        require(balance >= SEED_BOND, "insufficient seed balance");
        address predicted = d.factory.predictAddress(SYMBOL);
        T.CreateParams memory params =
            T.CreateParams(SYMBOL, address(d.nullAdapter), bytes32(0), INITIAL_PRICE, DEPTH, SEED_BOND);

        vm.startBroadcast(sender);
        require(d.vault.token().approve(address(d.factory), SEED_BOND), "approve failed");
        market = Market(d.factory.createMarket(params));
        vm.stopBroadcast();

        require(address(market) == predicted && d.factory.isMarket(predicted), "wrong created market");
        require(d.factory.marketCount() == count + 1, "wrong market count");
        require(address(market.vault()) == address(d.vault), "wrong market vault");
        require(!market.externalIndex() && market.feedId() == bytes32(0), "unexpected oracle");
        T.MarketConfig memory expected = d.factory.launchConfig(sender, address(d.nullAdapter));
        expected.statusSince = uint64(block.number);
        require(keccak256(abi.encode(market.config())) == keccak256(abi.encode(expected)), "wrong launch caps");
        require(market.markPrice() == INITIAL_PRICE && market.ammState().quoteReserve == DEPTH, "wrong curve");
        (uint256 longs, uint256 shorts, uint256 cap) = market.openInterest();
        require(longs == 0 && shorts == 0 && cap == 20_000e18, "wrong initial OI");
        require(d.vault.ledger(predicted).insurance == 2_000e18, "wrong seed insurance");
        require(d.vault.protocolReserve() == reserve, "reserve changed");
        require(d.vault.token().balanceOf(address(d.vault)) == cash + SEED_BOND, "seed not cash backed");
        require(d.vault.token().balanceOf(sender) == balance - SEED_BOND, "wrong seed debit");
        require(d.vault.token().allowance(sender, address(d.factory)) == 0, "unused seed approval");
        d.vault.requireOpenAllowed(predicted);

        string memory key = "demo-market";
        vm.serializeString(key, "symbol", SYMBOL);
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeBool(key, "mockCollateral", true);
        vm.serializeAddress(key, "market", predicted);
        vm.serializeAddress(key, "creator", sender);
        vm.serializeAddress(key, "factory", address(d.factory));
        vm.serializeAddress(key, "vault", address(d.vault));
        vm.serializeAddress(key, "collateral", c.usdc);
        vm.serializeAddress(key, "priceSource", address(d.nullAdapter));
        vm.serializeUint(key, "initialPriceWad", INITIAL_PRICE);
        vm.serializeUint(key, "depthWad", DEPTH);
        vm.serializeUint(key, "seedBondUnits", SEED_BOND);
        string memory json = vm.serializeBytes32(key, "runtimeCodeHash", predicted.codehash);
        vm.writeJson(json, vm.envString("DEMO_MARKET_OUTPUT"));
    }
}
