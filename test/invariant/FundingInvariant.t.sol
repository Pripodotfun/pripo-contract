// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {FixedPointMath as F} from "../../src/libraries/FixedPointMath.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {FundingHarness} from "../helpers/FundingHarness.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

contract FundingHandler is Test {
    FundingHarness public immutable book;

    constructor(FundingHarness book_) {
        book = book_;
    }

    function resize(uint8 actor, uint96 sizeSeed, bool isLong) external {
        uint256 size = sizeSeed % 13 == 0 ? 0 : bound(sizeSeed, 1, 100e18);
        book.resize(actor % 8, isLong ? int256(size) : -int256(size));
    }

    function accrue(int96 rateSeed, uint16 elapsedSeed) external {
        int256 rate = bound(int256(rateSeed), -1e15, 1e15);
        book.accrue(rate, uint64(bound(elapsedSeed, 0, 600)));
    }

    function settle(uint8 actor) external {
        book.settle(actor % 8);
    }

    function sweep() external {
        book.sweep();
    }
}

/// @notice Funding ledger invariants only. Full ERC-20 vault/market invariants are the next milestone.
contract FundingInvariantTest is StdInvariant, Test {
    FundingHarness internal book;
    FundingHandler internal handler;

    function setUp() public {
        book = new FundingHarness();
        book.resize(0, 1e18);
        book.resize(1, -1e18);
        handler = new FundingHandler(book);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.resize.selector;
        selectors[1] = handler.accrue.selector;
        selectors[2] = handler.settle.selector;
        selectors[3] = handler.sweep.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_CashWeightedSumsAndExactFundingSurplus() public view {
        T.FundingState memory f = book.state();
        int256 longWeighted;
        int256 shortWeighted;
        int256 margins;
        uint256 longs;
        uint256 shorts;
        for (uint256 i; i < 8; ++i) {
            (int256 size, int256 snapshot, int256 margin) = book.accounts(i);
            margins += margin;
            if (size > 0) {
                longs += uint256(size);
                longWeighted += F.signedProduct(uint256(size), snapshot);
            } else if (size < 0) {
                shorts += F.abs(size);
                shortWeighted += F.signedProduct(F.abs(size), snapshot);
            } else {
                assertEq(snapshot, 0);
                assertEq(margin, 0);
            }
        }
        assertEq(book.longs(), longs);
        assertEq(book.shorts(), shorts);
        assertEq(f.longWeighted, longWeighted);
        assertEq(f.shortWeighted, shortWeighted);
        assertEq(book.marginTotal(), margins);
        assertEq(book.cash(), margins + book.pool() + int256(book.insurance()));
        assertEq(int256(book.surplus()), int256(f.remainderHi) + int256(f.roundingHi) - int256(f.sweptHi));
        assertLe(f.roundingHi, book.settlementCount() * 1e18);
    }

    function afterInvariant() public {
        for (uint256 i; i < 8; ++i) {
            book.resize(i, 0);
        }
        book.sweep();
        assertEq(book.pool(), 0);
        assertEq(book.pending(), 0);
        assertEq(book.surplus(), 0);
        assertEq(book.sweep(), 0);
    }
}
