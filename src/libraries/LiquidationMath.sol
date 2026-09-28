// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FixedPointMath as F} from "./FixedPointMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Launch liquidation sizing and penalty rounding.
library LiquidationMath {
    function fraction(uint256 size, uint256 referencePrice, bool externalIndex, bool degraded)
        internal
        pure
        returns (uint256)
    {
        // One base wei cannot be halved; its final close must remain possible.
        if (size <= 1) return F.WAD;
        uint256 notional = Math.mulDiv(size, referencePrice, F.WAD, Math.Rounding.Ceil);
        return degraded || notional > (externalIndex ? 50_000e18 : 10_000e18) ? F.WAD / 2 : F.WAD;
    }

    function penalty(uint256 closedQuote, uint16 penaltyBps) internal pure returns (uint256) {
        return Math.mulDiv(closedQuote, penaltyBps, F.BPS, Math.Rounding.Ceil);
    }
}
