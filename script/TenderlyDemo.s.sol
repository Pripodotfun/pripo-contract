// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FeeSweeper} from "../src/FeeSweeper.sol";
import {InsuranceBackstop} from "../src/InsuranceBackstop.sol";
import {MarginVault} from "../src/MarginVault.sol";
import {Market} from "../src/Market.sol";
import {IFactoryVault, MarketFactory} from "../src/MarketFactory.sol";
import {IMarginVault} from "../src/interfaces/IMarginVault.sol";
import {PripoTypes as T} from "../src/types/PripoTypes.sol";
import {PripoDeployment} from "./DeployPripo.s.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @dev The runner authenticates the hosted fork separately and records its actual EVM domain.
///      This demo uses unsigned fork transactions and direct account roles, without typed signatures.
abstract contract TenderlyDemoTools is PripoDeployment {
    function _demoSender() internal view returns (address sender) {
        require(block.chainid == 999143 && vm.envBool("TENDERLY_SINGLE_ACCOUNT_DEMO"), "isolated demo only");
        sender = vm.envAddress("DEPLOYER");
        require(sender == 0x00000000000000000000000000000000000A11cE, "wrong demo account");
    }

    function _demo() internal view returns (Config memory c, Deployment memory d, address sender) {
        sender = _demoSender();
        (c, d) = _readManifest();
        _verify(c, d);
        require(c.governor == sender && c.guardian == sender && c.treasury == sender, "wrong demo roles");
    }
}

/// @notice Reuse verified immutable implementations and deploy separate demo custody and factory contracts.
contract DeployTenderlyDemo is TenderlyDemoTools {
    function run() external {
        address sender = _demoSender();
        (Config memory c, Deployment memory d) = _readManifest();
        _verify(c, d);
        require(c.chainId == 999143, "wrong source network");
        c.governor = sender;
        c.guardian = sender;
        c.treasury = sender;
        vm.startBroadcast(sender);
        d.vault = MarginVault(
            address(
                new ERC1967Proxy(
                    address(d.implementation), abi.encodeCall(MarginVault.initialize, (c.usdc, sender, sender, sender))
                )
            )
        );
        d.backstop = new InsuranceBackstop(address(d.vault));
        d.sweeper = new FeeSweeper(IMarginVault(address(d.vault)));
        d.factory = new MarketFactory(
            IFactoryVault(address(d.vault)), address(d.market), address(d.nullAdapter), c.slashToReserve
        );
        vm.stopBroadcast();
        _verify(c, d);
        _writeManifest(c, d, sender, vm.envString("DEMO_OUTPUT"));
    }
}

contract FundTenderlyDemo is TenderlyDemoTools {
    function run() external {
        (, Deployment memory d, address sender) = _demo();
        require(address(d.vault.backstopController()) == address(0), "setup already started");
        require(!d.vault.registrars(address(d.factory)) && d.vault.protocolReserve() == 0, "inspect existing setup");
        require(d.vault.token().balanceOf(sender) >= 12_000e6, "insufficient fork USDC");
        vm.startBroadcast(sender);
        d.vault.setBackstopController(d.backstop);
        d.vault.setRegistrar(address(d.factory), true);
        require(d.vault.token().approve(address(d.vault), 10_000e6), "reserve approval failed");
        d.vault.fundProtocolReserve(10_000e6);
        vm.stopBroadcast();
        require(address(d.vault.backstopController()) == address(d.backstop), "wrong backstop");
        require(d.vault.registrars(address(d.factory)), "factory not registered");
        require(d.vault.protocolReserve() == 10_000e18, "wrong reserve");
        require(d.vault.token().balanceOf(address(d.vault)) == 10_000e6, "reserve not cash backed");
    }
}

contract CreateTenderlyDemoMarket is TenderlyDemoTools {
    string public constant SYMBOL = "PRIPO:DEMO";

    function run() external returns (Market market) {
        (, Deployment memory d, address sender) = _demo();
        require(d.factory.marketCount() == 0, "demo market already exists");
        require(d.vault.protocolReserve() >= d.vault.reserveFloor(), "reserve not funded");
        address predicted = d.factory.predictAddress(SYMBOL);
        T.CreateParams memory params =
            T.CreateParams(SYMBOL, address(d.nullAdapter), bytes32(0), 100e18, 200_000e18, 2_000e6);
        vm.startBroadcast(sender);
        require(d.vault.token().approve(address(d.factory), 2_000e6), "seed approval failed");
        market = Market(d.factory.createMarket(params));
        vm.stopBroadcast();
        require(address(market) == predicted && d.factory.isMarket(predicted), "wrong market");
        require(address(market.vault()) == address(d.vault) && !market.externalIndex(), "wrong market config");
        require(market.markPrice() == 100e18 && market.positionCount() == 0, "wrong initial state");
        require(d.vault.ledger(predicted).insurance == 2_000e18, "wrong seed insurance");
        require(d.vault.protocolReserve() == 10_000e18, "reserve changed");
        require(d.vault.token().balanceOf(address(d.vault)) == 12_000e6, "cash mismatch");
        d.vault.requireOpenAllowed(predicted);
        string memory key = "tenderly-demo-market";
        vm.serializeString(key, "symbol", SYMBOL);
        vm.serializeAddress(key, "market", predicted);
        vm.serializeAddress(key, "factory", address(d.factory));
        vm.serializeAddress(key, "vault", address(d.vault));
        vm.serializeAddress(key, "usdc", address(d.vault.token()));
        vm.serializeBool(key, "externalIndex", false);
        string memory json = vm.serializeBool(key, "demoOnly", true);
        vm.writeJson(json, vm.envString("DEMO_MARKET_OUTPUT"));
    }
}
