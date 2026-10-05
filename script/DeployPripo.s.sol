// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FeeSweeper} from "../src/FeeSweeper.sol";
import {InsuranceBackstop} from "../src/InsuranceBackstop.sol";
import {MarginVault} from "../src/MarginVault.sol";
import {Market} from "../src/Market.sol";
import {IFactoryVault, MarketFactory} from "../src/MarketFactory.sol";
import {NullAdapter} from "../src/adapters/NullAdapter.sol";
import {PythAdapter} from "../src/adapters/PythAdapter.sol";
import {IMarginVault} from "../src/interfaces/IMarginVault.sol";
import {IPythPriceFeed} from "../src/interfaces/IPythPriceFeed.sol";
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
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Script} from "forge-std/Script.sol";

/// @notice Deploy with final roles, then configure from the Governor. No private keys are read by this script.
/// @dev Foundry deploys and links the library dependency graph before the recorded contract creations.
abstract contract PripoDeployment is Script {
    struct Config {
        uint256 chainId;
        address usdc;
        address pythCore;
        address governor;
        address guardian;
        address treasury;
        uint32 maxUpdateAgeSeconds;
        uint32 blockTimeMillis;
        bool slashToReserve;
    }

    struct Deployment {
        MarginVault implementation;
        MarginVault vault;
        Market market;
        NullAdapter nullAdapter;
        PythAdapter pythAdapter;
        InsuranceBackstop backstop;
        FeeSweeper sweeper;
        MarketFactory factory;
    }

    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function _validate(Config memory c) internal view {
        require(c.chainId == 143 || c.chainId == 10143 || c.chainId == 999143, "unsupported network");
        require(block.chainid == c.chainId, "wrong chain");
        require(c.governor != address(0) && c.guardian != address(0) && c.treasury != address(0), "missing role");
        require(c.usdc.code.length != 0 && c.pythCore.code.length != 0, "missing dependency");
        require(IERC20Metadata(c.usdc).decimals() == 6, "USDC decimals");
        require(c.maxUpdateAgeSeconds == 3 && c.blockTimeMillis == 300, "unsupported oracle timing");
        bytes[] memory empty = new bytes[](0);
        IPythPriceFeed(c.pythCore).getUpdateFee(empty);
    }

    function _deploy(Config memory c, address sender) internal returns (Deployment memory d) {
        _validate(c);
        require(sender != address(0) && sender.code.length == 0, "invalid deployer");
        vm.startBroadcast(sender);
        d.implementation = new MarginVault();
        d.vault = MarginVault(
            address(
                new ERC1967Proxy(
                    address(d.implementation),
                    abi.encodeCall(MarginVault.initialize, (c.usdc, c.governor, c.guardian, c.treasury))
                )
            )
        );
        d.market = new Market();
        d.nullAdapter = new NullAdapter();
        d.pythAdapter = new PythAdapter(IPythPriceFeed(c.pythCore), c.maxUpdateAgeSeconds, c.blockTimeMillis);
        d.backstop = new InsuranceBackstop(address(d.vault));
        d.sweeper = new FeeSweeper(IMarginVault(address(d.vault)));
        d.factory = new MarketFactory(
            IFactoryVault(address(d.vault)), address(d.market), address(d.nullAdapter), c.slashToReserve
        );
        vm.stopBroadcast();
        _verify(c, d);
    }

    function _configure(Config memory c, Deployment memory d) internal {
        _verify(c, d);
        address controller = address(d.vault.backstopController());
        require(controller == address(0) || controller == address(d.backstop), "unexpected backstop");
        vm.startBroadcast(c.governor);
        if (controller == address(0)) d.vault.setBackstopController(d.backstop);
        if (!d.vault.registrars(address(d.factory))) d.vault.setRegistrar(address(d.factory), true);
        if (!d.factory.allowedAdapters(address(d.pythAdapter)) && d.factory.adapterReadyAt(address(d.pythAdapter)) == 0)
        {
            d.factory.scheduleAdapter(address(d.pythAdapter));
        }
        vm.stopBroadcast();
    }

    function _verify(Config memory c, Deployment memory d) internal view {
        _validate(c);
        require(d.vault.governor() == c.governor, "wrong governor");
        require(d.vault.guardian() == c.guardian && d.vault.treasury() == c.treasury, "wrong roles");
        require(address(d.vault.token()) == c.usdc, "wrong token");
        require(
            vm.load(address(d.vault), IMPLEMENTATION_SLOT) == bytes32(uint256(uint160(address(d.implementation)))),
            "wrong proxy implementation"
        );
        require(address(d.factory.vault()) == address(d.vault), "wrong factory vault");
        require(d.factory.marketImplementation() == address(d.market), "wrong market implementation");
        require(d.factory.nullAdapter() == address(d.nullAdapter), "wrong null adapter");
        require(d.factory.slashToReserve() == c.slashToReserve, "wrong slash destination");
        require(address(d.pythAdapter.pyth()) == c.pythCore, "wrong Pyth provider");
        require(d.pythAdapter.maxUpdateAgeSeconds() == c.maxUpdateAgeSeconds, "wrong update age");
        require(d.pythAdapter.blockTimeMillis() == c.blockTimeMillis, "wrong block time");
        require(d.backstop.vault() == address(d.vault), "wrong backstop vault");
        require(address(d.sweeper.vault()) == address(d.vault), "wrong sweeper vault");
    }

    function _config(string memory json) internal view returns (Config memory c) {
        c.chainId = vm.parseJsonUint(json, ".chainId");
        if (vm.keyExistsJson(json, ".rehearsalOnly") && vm.parseJsonBool(json, ".rehearsalOnly")) {
            require(c.chainId == 999143, "rehearsal config cannot target a public chain");
        }
        c.usdc = vm.parseJsonAddress(json, ".usdc");
        c.pythCore = vm.parseJsonAddress(json, ".pythCore");
        c.governor = vm.parseJsonAddress(json, ".governor");
        c.guardian = vm.parseJsonAddress(json, ".guardian");
        c.treasury = vm.parseJsonAddress(json, ".treasury");
        c.maxUpdateAgeSeconds = SafeCast.toUint32(vm.parseJsonUint(json, ".maxUpdateAgeSeconds"));
        c.blockTimeMillis = SafeCast.toUint32(vm.parseJsonUint(json, ".blockTimeMillis"));
        c.slashToReserve = vm.parseJsonBool(json, ".slashToReserve");
    }

    function _readManifest() internal view returns (Config memory c, Deployment memory d) {
        string memory json = vm.readFile(vm.envString("DEPLOY_OUTPUT"));
        c = _config(json);
        d.implementation = MarginVault(vm.parseJsonAddress(json, ".vaultImplementation"));
        d.vault = MarginVault(vm.parseJsonAddress(json, ".vault"));
        d.market = Market(vm.parseJsonAddress(json, ".marketImplementation"));
        d.nullAdapter = NullAdapter(vm.parseJsonAddress(json, ".nullAdapter"));
        d.pythAdapter = PythAdapter(vm.parseJsonAddress(json, ".pythAdapter"));
        d.backstop = InsuranceBackstop(vm.parseJsonAddress(json, ".backstop"));
        d.sweeper = FeeSweeper(vm.parseJsonAddress(json, ".sweeper"));
        d.factory = MarketFactory(vm.parseJsonAddress(json, ".factory"));
        address[] memory contracts = vm.parseJsonAddressArray(json, ".contracts");
        bytes32[] memory hashes = vm.parseJsonBytes32Array(json, ".runtimeCodeHashes");
        require(contracts.length == 19 && hashes.length == contracts.length, "incomplete manifest");
        address[8] memory core = [
            address(d.implementation),
            address(d.vault),
            address(d.market),
            address(d.nullAdapter),
            address(d.pythAdapter),
            address(d.backstop),
            address(d.sweeper),
            address(d.factory)
        ];
        for (uint256 i; i < core.length; ++i) {
            require(contracts[i] == core[i], "manifest address mismatch");
        }
        for (uint256 i; i < contracts.length; ++i) {
            require(contracts[i].code.length != 0 && contracts[i].codehash == hashes[i], "runtime mismatch");
        }
    }

    function _writeManifest(Config memory c, Deployment memory d, address sender, string memory path) internal {
        string memory key = "deployment";
        vm.serializeUint(key, "chainId", c.chainId);
        vm.serializeBool(key, "rehearsalOnly", c.chainId == 999143);
        vm.serializeUint(key, "blockNumber", block.number);
        vm.serializeAddress(key, "deployer", sender);
        vm.serializeAddress(key, "usdc", c.usdc);
        vm.serializeAddress(key, "pythCore", c.pythCore);
        vm.serializeAddress(key, "governor", c.governor);
        vm.serializeAddress(key, "guardian", c.guardian);
        vm.serializeAddress(key, "treasury", c.treasury);
        vm.serializeUint(key, "maxUpdateAgeSeconds", c.maxUpdateAgeSeconds);
        vm.serializeUint(key, "blockTimeMillis", c.blockTimeMillis);
        vm.serializeBool(key, "slashToReserve", c.slashToReserve);
        vm.serializeAddress(key, "vaultImplementation", address(d.implementation));
        vm.serializeAddress(key, "vault", address(d.vault));
        vm.serializeAddress(key, "marketImplementation", address(d.market));
        vm.serializeAddress(key, "nullAdapter", address(d.nullAdapter));
        vm.serializeAddress(key, "pythAdapter", address(d.pythAdapter));
        vm.serializeAddress(key, "backstop", address(d.backstop));
        vm.serializeAddress(key, "sweeper", address(d.sweeper));
        vm.serializeAddress(key, "factory", address(d.factory));
        address[] memory contracts = new address[](19);
        contracts[0] = address(d.implementation);
        contracts[1] = address(d.vault);
        contracts[2] = address(d.market);
        contracts[3] = address(d.nullAdapter);
        contracts[4] = address(d.pythAdapter);
        contracts[5] = address(d.backstop);
        contracts[6] = address(d.sweeper);
        contracts[7] = address(d.factory);
        contracts[8] = address(FundingMath);
        contracts[9] = address(MarkTwap);
        contracts[10] = address(MarketFundingCapacity);
        contracts[11] = address(MarketAccounting);
        contracts[12] = address(MarketLens);
        contracts[13] = address(MarketSettlement);
        contracts[14] = address(MarketAdl);
        contracts[15] = address(MarketTrading);
        contracts[16] = address(MarketLiquidation);
        contracts[17] = address(MarketMargin);
        contracts[18] = address(MarketMaintenance);
        bytes32[] memory hashes = new bytes32[](contracts.length);
        for (uint256 i; i < contracts.length; ++i) {
            require(contracts[i].code.length != 0, "missing deployed code");
            hashes[i] = contracts[i].codehash;
        }
        vm.serializeAddress(key, "contracts", contracts);
        vm.serializeBytes32(key, "runtimeCodeHashes", hashes);
        address[] memory targets = new address[](3);
        targets[0] = address(d.vault);
        targets[1] = address(d.vault);
        targets[2] = address(d.factory);
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(MarginVault.setBackstopController, (d.backstop));
        calls[1] = abi.encodeCall(MarginVault.setRegistrar, (address(d.factory), true));
        calls[2] = abi.encodeCall(MarketFactory.scheduleAdapter, (address(d.pythAdapter)));
        vm.serializeAddress(key, "governanceTargets", targets);
        vm.serializeUint(key, "governanceValues", new uint256[](3));
        string memory json = vm.serializeBytes(key, "governanceCalldata", calls);
        vm.writeJson(json, path);
    }
}

contract DeployPripo is PripoDeployment {
    function run() external returns (Deployment memory d) {
        string memory json = vm.readFile(vm.envString("DEPLOY_CONFIG"));
        Config memory c = _config(json);
        address sender = vm.envAddress("DEPLOYER");
        d = _deploy(c, sender);
        _writeManifest(c, d, sender, vm.envString("DEPLOY_OUTPUT"));
    }
}

contract ConfigurePripo is PripoDeployment {
    /// @notice EOA Governor execution; multisig Governors use the manifest's ordered governance calls.
    /// @dev Safe to rerun after partial execution: existing bindings are checked and pending delays retained.
    function configure() external {
        (Config memory c, Deployment memory d) = _readManifest();
        _configure(c, d);
    }

    /// @notice Permissionless activation after the factory's full governance delay has elapsed.
    function activate() external {
        (Config memory c, Deployment memory d) = _readManifest();
        _verify(c, d);
        require(d.vault.registrars(address(d.factory)), "factory not configured");
        require(address(d.vault.backstopController()) == address(d.backstop), "backstop not configured");
        if (d.factory.allowedAdapters(address(d.pythAdapter))) return;
        uint256 ready = d.factory.adapterReadyAt(address(d.pythAdapter));
        if (ready == 0 || block.timestamp < ready) revert MarketFactory.GovernanceNotReady(ready);
        vm.startBroadcast(vm.envAddress("DEPLOYER"));
        d.factory.activateAdapter(address(d.pythAdapter));
        vm.stopBroadcast();
    }
}
