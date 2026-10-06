// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Market} from "../src/Market.sol";
import {PripoTypes as T} from "../src/types/PripoTypes.sol";
import {TestnetDeployment} from "./DeployTestnet.s.sol";

/// @notice Deposit demo collateral and open one long unit with a fixed maximum fill price.
contract OpenDemoPosition is TestnetDeployment {
    uint256 public constant DEPOSIT = 100e6;
    int256 public constant SIZE = 1e18;
    uint256 public constant LIMIT_PRICE = 101e18;

    function run() external {
        require(block.chainid == 10143, "testnet only");
        string memory source = vm.readFile(vm.envString("DEPLOY_OUTPUT"));
        require(vm.parseJsonBool(source, ".mockCollateral"), "mock collateral required");
        (Config memory c, Deployment memory d) = _readManifest();
        _verify(c, d);
        require(c.usdc.codehash == vm.parseJsonBytes32(source, ".mockTokenCodeHash"), "wrong mock token");
        string memory saved = vm.readFile(vm.envString("DEMO_MARKET_INPUT"));
        Market market = Market(vm.parseJsonAddress(saved, ".market"));
        require(address(market).codehash == vm.parseJsonBytes32(saved, ".runtimeCodeHash"), "wrong market code");
        require(d.factory.marketForSymbol(keccak256("PRIPO:DEMO")) == address(market), "wrong demo market");
        require(address(market.vault()) == address(d.vault) && !market.externalIndex(), "wrong market binding");
        address sender = _signer();
        require(market.position(sender).size == 0, "position already exists");
        d.vault.requireOpenAllowed(address(market));
        (uint256 average, uint256 fee, uint256 margin, uint256 mark) = market.quoteOpenFor(sender, SIZE);
        require(average <= LIMIT_PRICE, "quote exceeds limit");
        require(margin + fee <= DEPOSIT * 1e12, "quote exceeds deposit budget");
        uint256 reserve = d.vault.protocolReserve();
        uint256 cash = d.vault.token().balanceOf(address(d.vault));
        uint256 balance = d.vault.token().balanceOf(sender);
        uint256 free = d.vault.freeBalance(sender);
        require(balance >= DEPOSIT, "insufficient demo collateral");

        vm.startBroadcast(sender);
        require(d.vault.token().approve(address(d.vault), DEPOSIT), "approve failed");
        d.vault.deposit(DEPOSIT);
        market.open(SIZE, LIMIT_PRICE, "");
        vm.stopBroadcast();

        T.Position memory position = market.position(sender);
        require(position.size == SIZE && position.margin == margin, "wrong opened position");
        require(position.entryCost == average && market.markPrice() == mark, "wrong execution price");
        require(d.vault.freeBalance(sender) == free + DEPOSIT * 1e12 - margin - fee, "wrong free balance");
        require(d.vault.protocolReserve() == reserve, "reserve changed");
        require(d.vault.token().balanceOf(address(d.vault)) == cash + DEPOSIT, "deposit not cash backed");
        require(d.vault.token().balanceOf(sender) == balance - DEPOSIT, "wrong deposit debit");
        require(d.vault.token().allowance(sender, address(d.vault)) == 0, "unused approval");
        (, bool liquidatable) = market.health(sender);
        require(!liquidatable, "opened position unhealthy");

        string memory key = "demo-position";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeAddress(key, "market", address(market));
        vm.serializeAddress(key, "trader", sender);
        vm.serializeUint(key, "depositUnits", DEPOSIT);
        vm.serializeInt(key, "sizeWad", SIZE);
        vm.serializeUint(key, "limitPriceWad", LIMIT_PRICE);
        vm.serializeUint(key, "averagePriceWad", average);
        vm.serializeUint(key, "marginWad", margin);
        vm.serializeUint(key, "feeWad", fee);
        vm.serializeUint(key, "freeBalanceWad", d.vault.freeBalance(sender));
        string memory json = vm.serializeUint(key, "markPriceWad", mark);
        vm.writeJson(json, vm.envString("DEMO_POSITION_OUTPUT"));
    }
}
