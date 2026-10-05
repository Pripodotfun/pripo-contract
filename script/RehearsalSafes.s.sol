// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PripoDeployment} from "./DeployPripo.s.sol";
import {Script} from "forge-std/Script.sol";

interface IRehearsalSafe {
    function setup(address[] calldata, uint256, address, bytes calldata, address, address, uint256, address payable)
        external;
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function nonce() external view returns (uint256);
    function getTransactionHash(
        address,
        uint256,
        bytes calldata,
        uint8,
        uint256,
        uint256,
        uint256,
        address,
        address,
        uint256
    ) external view returns (bytes32);
    function execTransaction(
        address,
        uint256,
        bytes calldata,
        uint8,
        uint256,
        uint256,
        uint256,
        address,
        address payable,
        bytes calldata
    ) external payable returns (bool);
}

interface IRehearsalSafeFactory {
    function createProxyWithNonce(address singleton, bytes calldata initializer, uint256 saltNonce)
        external
        returns (address);
}

/// @dev Public deterministic signing keys are exclusively for the isolated 999143 rehearsal chain.
abstract contract RehearsalSafeTools is Script {
    address internal constant SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address internal constant FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    bytes32 internal constant SINGLETON_HASH = 0x1fe2df852ba3299d6534ef416eefa406e56ced995bca886ab7a553e6d0c5e1c4;
    bytes32 internal constant FACTORY_HASH = 0x50c3cdc4074750a7a974204a716c999edd37482f907608d960b2b025ee0b3317;

    function _forkOnly() internal view {
        require(block.chainid == 999143, "rehearsal chain only");
        require(SINGLETON.codehash == SINGLETON_HASH && FACTORY.codehash == FACTORY_HASH, "unverified Safe deployment");
    }

    function _key(string memory role, uint256 index) internal pure returns (uint256) {
        // 128-bit nonzero scalars are valid secp256k1 keys. These deliberately carry no secrecy.
        return uint256(uint128(uint256(keccak256(abi.encode("pripo-public-rehearsal-only", role, index))))) + 1;
    }

    function _owners(string memory role, uint256 count) internal pure returns (address[] memory owners) {
        owners = new address[](count);
        for (uint256 i; i < count; ++i) {
            owners[i] = vm.addr(_key(role, i));
        }
    }

    function _create(string memory role, uint256 count, uint256 threshold, uint256 salt)
        internal
        returns (address safe)
    {
        _forkOnly();
        address[] memory owners = _owners(role, count);
        bytes memory initializer = abi.encodeCall(
            IRehearsalSafe.setup,
            (owners, threshold, address(0), bytes(""), address(0), address(0), 0, payable(address(0)))
        );
        safe = IRehearsalSafeFactory(FACTORY)
            .createProxyWithNonce(SINGLETON, initializer, uint256(keccak256(abi.encode(role, salt))));
        require(IRehearsalSafe(safe).getThreshold() == threshold, "wrong Safe threshold");
        require(
            keccak256(abi.encode(IRehearsalSafe(safe).getOwners())) == keccak256(abi.encode(owners)),
            "wrong Safe owners"
        );
    }

    function _governorSignatures(IRehearsalSafe safe, address target, bytes memory data)
        internal
        view
        returns (bytes memory signatures)
    {
        _forkOnly();
        require(safe.getThreshold() == 3, "Governor must be 3-of-5");
        require(
            keccak256(abi.encode(safe.getOwners())) == keccak256(abi.encode(_owners("governor", 5))),
            "not rehearsal Governor"
        );
        uint256[3] memory keys = [_key("governor", 0), _key("governor", 1), _key("governor", 2)];
        for (uint256 i = 1; i < keys.length; ++i) {
            for (uint256 j = i; j > 0 && vm.addr(keys[j]) < vm.addr(keys[j - 1]); --j) {
                (keys[j], keys[j - 1]) = (keys[j - 1], keys[j]);
            }
        }
        bytes32 hash = safe.getTransactionHash(target, 0, data, 0, 0, 0, 0, address(0), address(0), safe.nonce());
        for (uint256 i; i < keys.length; ++i) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], hash);
            signatures = bytes.concat(signatures, abi.encodePacked(r, s, v));
        }
    }
}

contract CreateRehearsalSafes is RehearsalSafeTools {
    function run() external {
        _forkOnly();
        address sender = vm.envAddress("DEPLOYER");
        uint256 salt = vm.envUint("REHEARSAL_SAFE_SALT");
        vm.startBroadcast(sender);
        address governor = _create("governor", 5, 3, salt);
        address guardian = _create("guardian", 3, 2, salt);
        address treasury = _create("treasury", 5, 3, salt);
        address council = _create("council", 5, 3, salt);
        vm.stopBroadcast();
        string memory key = "rehearsal-config";
        vm.serializeJson(key, vm.readFile("config/deploy-tenderly.example.json"));
        vm.serializeAddress(key, "governor", governor);
        vm.serializeAddress(key, "guardian", guardian);
        vm.serializeAddress(key, "treasury", treasury);
        vm.serializeAddress(key, "council", council);
        string memory json = vm.serializeBool(key, "rehearsalOnly", true);
        vm.writeJson(json, vm.envString("DEPLOY_CONFIG"));
    }
}

/// @notice Execute the unchanged deployment manifest's Governor calls through an actual 3-of-5 Safe.
contract ConfigureRehearsalSafes is PripoDeployment, RehearsalSafeTools {
    function run() external {
        _forkOnly();
        (Config memory c, Deployment memory d) = _readManifest();
        _verify(c, d);
        require(c.chainId == 999143, "wrong rehearsal manifest");
        require(address(d.vault.backstopController()) == address(0), "setup already started; inspect Safe nonce");
        string memory json = vm.readFile(vm.envString("DEPLOY_OUTPUT"));
        address[] memory targets = vm.parseJsonAddressArray(json, ".governanceTargets");
        bytes[] memory calls = vm.parseJsonBytesArray(json, ".governanceCalldata");
        require(targets.length == 3 && calls.length == 3, "unexpected Governor bundle");
        IRehearsalSafe governor = IRehearsalSafe(c.governor);
        vm.startBroadcast(vm.envAddress("DEPLOYER"));
        for (uint256 i; i < targets.length; ++i) {
            bytes memory signatures = _governorSignatures(governor, targets[i], calls[i]);
            require(
                governor.execTransaction(
                    targets[i], 0, calls[i], 0, 0, 0, 0, address(0), payable(address(0)), signatures
                ),
                "Safe execution failed"
            );
        }
        vm.stopBroadcast();
        require(address(d.vault.backstopController()) == address(d.backstop), "backstop setup failed");
        require(d.vault.registrars(address(d.factory)), "registrar setup failed");
        require(d.factory.adapterReadyAt(address(d.pythAdapter)) >= block.timestamp + 1 days, "approval setup failed");
    }
}
