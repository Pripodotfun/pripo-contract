// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FeeSweeper} from "../src/FeeSweeper.sol";
import {InsuranceBackstop} from "../src/InsuranceBackstop.sol";
import {MarginVault} from "../src/MarginVault.sol";
import {IFactoryVault, MarketFactory} from "../src/MarketFactory.sol";
import {IMarginVault} from "../src/interfaces/IMarginVault.sol";
import {TestnetDeployment} from "./DeployTestnet.s.sol";
import {TestnetMockUSDC} from "./testnet/MockUSDC.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Reuse verified implementations/adapters; deploy new custody for six-decimal demo collateral.
contract DeployMockTestnet is TestnetDeployment {
    function run() external returns (Deployment memory d) {
        require(block.chainid == 10143, "testnet only");
        string memory source = vm.readFile(vm.envString("DEPLOY_OUTPUT"));
        Config memory c;
        (c, d) = _readManifest();
        _verify(c, d);
        require(c.chainId == 10143, "wrong source chain");
        address sender = _signer();
        require(c.governor == sender, "Governor requires separate signatures");
        address sourceVault = address(d.vault);
        address sourceFactory = address(d.factory);

        vm.startBroadcast(sender);
        TestnetMockUSDC token = new TestnetMockUSDC(sender);
        c.usdc = address(token);
        d.vault = MarginVault(
            address(
                new ERC1967Proxy(
                    address(d.implementation),
                    abi.encodeCall(MarginVault.initialize, (c.usdc, c.governor, c.guardian, c.treasury))
                )
            )
        );
        d.backstop = new InsuranceBackstop(address(d.vault));
        d.sweeper = new FeeSweeper(IMarginVault(address(d.vault)));
        d.factory = new MarketFactory(
            IFactoryVault(address(d.vault)), address(d.market), address(d.nullAdapter), c.slashToReserve
        );
        vm.stopBroadcast();
        _configure(c, d);
        vm.startBroadcast(sender);
        require(token.approve(address(d.vault), 10_000e6), "approve failed");
        d.vault.fundProtocolReserve(10_000e6);
        vm.stopBroadcast();

        _verify(c, d);
        require(d.vault.protocolReserve() == 10_000e18, "wrong reserve");
        require(token.balanceOf(address(d.vault)) == 10_000e6, "reserve not backed by tokens");
        require(token.balanceOf(sender) == 90_000e6, "wrong remaining balance");
        require(address(d.vault.backstopController()) == address(d.backstop), "backstop not configured");
        require(d.vault.registrars(address(d.factory)), "factory not registered");
        _writeMockManifest(source, c, d, sender, sourceVault, sourceFactory);
    }

    function _writeMockManifest(
        string memory source,
        Config memory c,
        Deployment memory d,
        address sender,
        address sourceVault,
        address sourceFactory
    ) internal {
        string memory key = "mock-testnet";
        vm.serializeJson(key, source);
        vm.serializeUint(key, "blockNumber", block.number);
        vm.serializeAddress(key, "deployer", sender);
        vm.serializeAddress(key, "sourceVault", sourceVault);
        vm.serializeAddress(key, "sourceFactory", sourceFactory);
        vm.serializeBool(key, "mockCollateral", true);
        vm.serializeString(key, "collateralName", "Pripo Mock USDC");
        vm.serializeString(key, "collateralSymbol", "mUSDC");
        vm.serializeAddress(key, "usdc", c.usdc);
        vm.serializeAddress(key, "vault", address(d.vault));
        vm.serializeAddress(key, "backstop", address(d.backstop));
        vm.serializeAddress(key, "sweeper", address(d.sweeper));
        vm.serializeAddress(key, "factory", address(d.factory));
        address[] memory contracts = vm.parseJsonAddressArray(source, ".contracts");
        contracts[1] = address(d.vault);
        contracts[5] = address(d.backstop);
        contracts[6] = address(d.sweeper);
        contracts[7] = address(d.factory);
        bytes32[] memory hashes = new bytes32[](contracts.length);
        for (uint256 i; i < contracts.length; ++i) {
            hashes[i] = contracts[i].codehash;
        }
        vm.serializeAddress(key, "contracts", contracts);
        vm.serializeBytes32(key, "runtimeCodeHashes", hashes);
        address[] memory created = new address[](5);
        created[0] = c.usdc;
        created[1] = address(d.vault);
        created[2] = address(d.backstop);
        created[3] = address(d.sweeper);
        created[4] = address(d.factory);
        vm.serializeAddress(key, "createdContracts", created);
        vm.serializeBytes32(key, "mockTokenCodeHash", c.usdc.codehash);
        address[] memory targets = new address[](3);
        targets[0] = address(d.vault);
        targets[1] = address(d.vault);
        targets[2] = address(d.factory);
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(MarginVault.setBackstopController, (d.backstop));
        calls[1] = abi.encodeCall(MarginVault.setRegistrar, (address(d.factory), true));
        calls[2] = abi.encodeCall(MarketFactory.scheduleAdapter, (address(d.pythAdapter)));
        vm.serializeAddress(key, "governanceTargets", targets);
        string memory json = vm.serializeBytes(key, "governanceCalldata", calls);
        vm.writeJson(json, vm.envString("MOCK_DEPLOY_OUTPUT"));
    }
}
