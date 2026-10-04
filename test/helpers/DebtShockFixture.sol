// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Market} from "../../src/Market.sol";
import {CurveMath as Curve} from "../../src/libraries/CurveMath.sol";
import {FixedPointMath as F} from "../../src/libraries/FixedPointMath.sol";
import {FundingMath as Funding} from "../../src/libraries/FundingMath.sol";
import {MarkTwap} from "../../src/libraries/MarkTwap.sol";
import {MarketAccounting as Engine} from "../../src/market/MarketAccounting.sol";
import {MarketFundingCapacity as Capacity} from "../../src/market/MarketFundingCapacity.sol";
import {MarketState as S} from "../../src/market/MarketState.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {MarketFixture} from "./MarketFixture.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @dev Seeds debt from the retired, uncapped funding model for recovery-engine tests only.
///      This transition is deliberately absent from production: all payer debits are injected before returning.
contract DebtShockMarket is Market {
    using MarkTwap for MarkTwap.State;

    function seedLegacyFundingDebt() external {
        S.Data storage s = S.load();
        require(s.pendingAdlCount == 0 && s._config.status < T.Status.Settling, "invalid shock phase");
        uint64 end = SafeCast.toUint64(block.number);
        if (s.externalIndex) {
            end = SafeCast.toUint64(Math.min(end, uint256(s._indexBlock) + s._config.degradeAfterBlocks + 1));
        }
        if (end > s._funding.lastBlock && s._config.status != T.Status.Degraded) {
            s._funding = Funding.accrue(
                s._funding,
                s.longSize,
                s.shortSize,
                Engine.cachedRate(s),
                s.externalIndex ? s._index : s._twap.consult(300, SafeCast.toUint64(block.number)),
                end,
                s._config.receiveCapX
            );
        }
        s._funding.lastBlock = SafeCast.toUint64(block.number);
        s.fundingBinding = address(0);
        for (uint256 i; i < s._accounts.length; ++i) {
            address user = s._accounts[i];
            T.Position storage p = s._positions[user];
            if (p.size == 0) continue;
            int256 index = p.size > 0 ? s._funding.longIndex : s._funding.shortIndex;
            int256 owed = F.ceilWad(F.signedProduct(F.abs(p.size), index - p.lastFundingIndex));
            if (owed > 0) {
                (s._funding, owed, p.lastFundingIndex) = Funding.settle(s._funding, p.size, p.lastFundingIndex);
                s.vault.settleFunding(user, owed);
            }
            Capacity.refresh(s, user);
        }
        s._twap.write(Curve.mark(s._amm), SafeCast.toUint64(block.number));
    }
}

abstract contract DebtShockFixture is MarketFixture {
    function _marketImplementation() internal virtual override returns (address) {
        return address(new DebtShockMarket());
    }

    function _seedLegacyFundingDebt(uint256 atBlock) internal {
        vm.roll(atBlock);
        DebtShockMarket(address(market)).seedLegacyFundingDebt();
    }
}
