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
        uint32 adlPendingWindow;
        uint16 maxPositionsPerMarket;
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
        uint32 slot;
        bool adlPending;
    }

    /// @notice Immutable schedules plus cumulative accounting for one selected liquidation portion.
    struct AdlPending {
        uint256 S0;
        uint256 E0;
        int256 V0; // A negative short boundary has no eligible long; a full scan proves insufficiency.
        int256 M0;
        int256 budget;
        uint256 matchedSize;
        uint256 reservedC;
        uint256 allowanceFromC;
        uint256 allowanceFromReserve;
        uint256 consumedC; // Net provisional coverage credited to locked collateral.
        uint256 replacedC;
        uint256 addedMargin;
        uint256 relief;
        uint256 allowanceConsumed;
        uint256 chunksMatched;
        uint64 since;
        uint32 cursor;
        bool isLong;
        bool active;
    }

    struct Ledger {
        uint256 protocolOwed;
        uint256 creatorOwed;
        uint256 insurance;
        int256 clearing;
        int256 fundingPool;
        uint256 skewPool;
    }

    /// @notice Actual cash reserved by a pending liquidation; each partition has one spending purpose.
    struct AdlReservation {
        uint256 lossCoverage;
        uint256 consumedCoverage;
        uint256 allowanceFromCoverage;
        uint256 allowanceFromReserve;
        bool active;
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

    struct SettlementQuote {
        uint256 price;
        uint256 positions;
        uint256 losingCollateral;
        uint256 profits;
        uint256 debt;
        int256 clearing;
        uint256 fundingSurplus;
        uint256 haircut;
        uint256 capitalRequired;
    }
}
