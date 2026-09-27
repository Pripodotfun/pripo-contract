// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Shared protocol types. Amounts are WAD unless explicitly stated otherwise.
library PripoTypes {
    enum Status {
        Active,
        Degraded,
        Paused,
        Settling,
        Settled
    }

    struct MarketConfig {
        address priceSource;
        address secondarySource;
        address creator;
        uint16 takerFeeBps;
        uint16 creatorShareBps;
        uint16 insuranceShareBps;
        uint16 referralShareBps;
        uint16 maxLeverageX;
        uint16 mmrBps;
        uint16 liqPenaltyBps;
        uint16 receiveCapX;
        uint16 sideCapBps;
        uint16 impactMarginBps;
        uint32 maxOracleAgeBlocks;
        uint32 degradeAfterBlocks;
        uint32 degradedTwapBlocks;
        uint64 fundingCapPerBlock;
        uint64 skewCoeff;
        Status status;
        uint64 statusSince;
    }

    struct AmmState {
        uint256 baseReserve;
        uint256 quoteReserve;
        uint256 k; // Unscaled product of the two WAD reserves (WAD squared).
        uint256 baseAtSeed;
        uint256 curveBase;
        int256 entryCostNet;
    }

    struct FundingState {
        int256 longIndex;
        int256 shortIndex;
        int256 longWeighted; // Index times base size, WAD squared.
        int256 shortWeighted;
        uint256 remainderHi;
        uint256 roundingHi;
        uint256 sweptHi;
        uint64 lastBlock;
    }

    struct OpenInterest {
        uint256 longSize;
        uint256 shortSize;
        uint256 longNotional;
        uint256 shortNotional;
        uint256 oiCap; // Quote insurance cap. Base side caps are enforced separately.
    }

    struct Position {
        int256 size;
        uint256 margin;
        uint256 entryCost;
        int256 lastFundingIndex;
    }

    struct Ledger {
        uint256 protocolOwed;
        uint256 creatorOwed;
        uint256 insurance;
        int256 clearing;
        int256 fundingPool;
        uint256 skewPool;
    }

    struct OperatorPolicy {
        uint64 expiry;
        uint128 maxNotionalPerTx;
        uint128 maxTotalNotional;
        uint128 usedNotional;
        bytes32 marketsRoot;
        bool canClose;
    }

    struct CreateParams {
        string symbol;
        address priceSource;
        bytes32 feedId;
        uint256 initialPrice;
        uint256 depth;
        uint256 seedBond; // Raw six-decimal USDC, unlike depth and initialPrice.
    }

    struct Fill {
        uint256 baseReserve;
        uint256 quoteReserve;
        uint256 quoteAmount;
        uint256 avgPrice;
        uint256 newMark;
    }

    struct FeeBreakdown {
        uint256 total;
        uint256 protocol;
        uint256 creator;
        uint256 insurance;
        uint256 referral;
    }
}
