// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarginVault} from "../interfaces/IMarginVault.sol";
import {FundingCapacityHeap} from "../libraries/FundingCapacityHeap.sol";
import {MarkTwap} from "../libraries/MarkTwap.sol";
import {PripoTypes as T} from "../types/PripoTypes.sol";

/// @notice Shared storage for the immutable implementation and its linked modules.
library MarketState {
    bytes32 private constant SLOT = keccak256("pripo.market.storage.v1");

    struct Data {
        IMarginVault vault;
        bytes32 feedId;
        bool externalIndex;
        bool guardianPaused;
        T.MarketConfig _config;
        T.AmmState _amm;
        T.FundingState _funding;
        uint256 longSize;
        uint256 shortSize;
        mapping(address => T.Position) _positions;
        MarkTwap.State _twap;
        uint256 _index;
        uint64 _indexBlock;
        address[] _accounts;
        mapping(address => uint256) _accountIndex;
        uint256 settlementPrice;
        uint256 settlementHaircut;
        uint256 settlementProfits;
        uint256 _positionCount;
        uint256[] _freeSlots;
        mapping(address => T.AdlPending) _pendingAdl;
        uint256 pendingAdlCount;
        FundingCapacityHeap.State longFundingCaps;
        FundingCapacityHeap.State shortFundingCaps;
        address fundingBinding;
    }

    struct OpenQuote {
        T.Fill fill;
        uint256 fee;
        uint256 margin;
        int256 newSize;
        uint256 newEntry;
    }

    struct CloseQuote {
        T.Fill fill;
        uint256 fee;
        int256 pnl;
        int256 closedSize;
        uint256 closedEntry;
    }

    struct Observation {
        uint256 price;
        uint64 updatedBlock;
        uint16 confidence;
        bool isExternal;
    }

    function load() internal pure returns (Data storage s) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") { s.slot := slot }
    }
}
