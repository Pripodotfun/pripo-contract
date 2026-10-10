// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Market} from "./Market.sol";
import {MarketFactory} from "./MarketFactory.sol";
import {IMarginVault} from "./interfaces/IMarginVault.sol";
import {IResolver} from "./interfaces/IResolver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Bonded terminal settlement for the new oracleless markets. Three of five
/// independent council addresses select one of the two bonded prices. All amounts
/// held here are raw six-decimal collateral tokens; market prices are WAD.
contract Resolver is IResolver, ReentrancyGuard {
    using SafeERC20 for IERC20;
    uint256 public constant DISPUTE_WINDOW = 24 hours;
    uint256 public constant COUNCIL_WINDOW = 48 hours;
    uint256 public constant STALE_AFTER = 30 days;
    uint256 public constant BOND = 2_500e6;
    MarketFactory public immutable factory;
    IMarginVault public immutable vault;
    IERC20 public immutable token;
    address[5] public council;
    mapping(address => uint8) public councilIndex;
    mapping(address => uint256) public credits;

    struct Declaration {
        uint64 expectedAt;
        uint8 kind;
        string evidenceURI;
    }

    struct Resolution {
        uint8 phase; // 0 none, 1 proposed, 2 disputed, 3 finalized
        address proposer;
        address disputer;
        uint64 proposedAt;
        uint64 windowEnd;
        uint64 councilEnd;
        uint256 proposedPrice;
        uint256 counterPrice;
        uint256 finalPrice;
        uint256 frozenTwap;
        uint8 votesProposed;
        uint8 votesCounter;
        string evidenceURI;
        string disputeReason;
    }
    mapping(address => Declaration) public declarations;
    mapping(address => Resolution) private _resolutions;

    event SettlementDeclared(address indexed market, uint8 kind, uint64 expectedAt, string evidenceURI);
    event SettlementEvidence(address indexed market, string evidenceURI);
    event DisputeEvidence(address indexed market, string reason, uint64 councilEnd);
    event CouncilVote(address indexed market, address indexed member, uint256 price);
    event SettlementFinalized(address indexed market, uint256 price, address winner, bool timeout);
    event BondCredit(address indexed user, uint256 amount);
    event BondClaimed(address indexed user, uint256 amount);

    constructor(MarketFactory factory_, address[5] memory members) {
        if (address(factory_).code.length == 0) revert InvalidAddress();
        factory = factory_;
        vault = factory_.vault();
        token = factory_.token();
        for (uint8 i; i < 5; ++i) {
            if (members[i] == address(0) || councilIndex[members[i]] != 0) revert InvalidAddress();
            council[i] = members[i];
            councilIndex[members[i]] = i + 1;
        }
    }

    function resolution(address market) external view returns (Resolution memory) {
        return _resolutions[market];
    }

    function state(address market) external view returns (uint8) {
        return _resolutions[market].phase;
    }

    function _market(address market) private view returns (Market m) {
        if (!factory.isMarket(market)) revert InvalidAddress();
        m = Market(market);
        if (m.externalIndex() || m.resolver() != address(this)) revert InvalidConfiguration();
    }

    /// @notice The current creator declares the event before anyone can bond its price.
    /// An inactive market also becomes eligible after 30 days without a price refresh.
    function declareSettlement(address market, uint8 kind, uint64 expectedAt, string calldata evidenceURI)
        external
        nonReentrant
    {
        _market(market);
        if (vault.creatorOf(market) != msg.sender) revert Unauthorized();
        if (
            _resolutions[market].phase != 0 || kind > 2 || expectedAt < block.timestamp
                || bytes(evidenceURI).length == 0 || bytes(evidenceURI).length > 512
        ) revert InvalidConfiguration();
        declarations[market] = Declaration(expectedAt, kind, evidenceURI);
        emit SettlementDeclared(market, kind, expectedAt, evidenceURI);
    }

    function propose(address market, uint256 price, string calldata evidenceURI) external nonReentrant {
        _propose(market, price, evidenceURI);
    }

    function startStaleWindDown(address market) external nonReentrant {
        Market m = _market(market);
        if (block.timestamp < uint256(m.lastTradeTimestamp()) + STALE_AFTER) revert MarketNotActive();
        _propose(market, m.twapPrice(), "Stale market: 30 days without price refresh");
    }

    function _propose(address market, uint256 price, string memory evidenceURI) private {
        Market m = _market(market);
        Resolution storage r = _resolutions[market];
        Declaration storage d = declarations[market];
        if (
            r.phase != 0 || price == 0 || price > 1e28 || bytes(evidenceURI).length == 0
                || bytes(evidenceURI).length > 512
        ) revert InvalidConfiguration();
        if (
            (d.expectedAt == 0 || block.timestamp < d.expectedAt)
                && block.timestamp < uint256(m.lastTradeTimestamp()) + STALE_AFTER
        ) revert MarketNotActive();
        _receiveBond();
        r.phase = 1;
        r.proposer = msg.sender;
        r.proposedAt = uint64(block.timestamp);
        r.windowEnd = uint64(block.timestamp + DISPUTE_WINDOW);
        r.proposedPrice = price;
        r.evidenceURI = evidenceURI;
        r.frozenTwap = m.beginResolution();
        emit SettlementProposed(market, msg.sender, price, r.windowEnd);
        emit SettlementEvidence(market, evidenceURI);
    }

    function dispute(address market, uint256 counterPrice) external nonReentrant {
        _dispute(market, counterPrice, "");
    }

    function disputeWithReason(address market, uint256 counterPrice, string calldata reason) external nonReentrant {
        _dispute(market, counterPrice, reason);
    }

    function _dispute(address market, uint256 counterPrice, string memory reason) private {
        Resolution storage r = _resolutions[market];
        if (
            r.phase != 1 || block.timestamp >= r.windowEnd || counterPrice == 0 || counterPrice > 1e28
                || counterPrice == r.proposedPrice || msg.sender == r.proposer || bytes(reason).length > 512
        ) revert InvalidConfiguration();
        _receiveBond();
        r.phase = 2;
        r.disputer = msg.sender;
        r.counterPrice = counterPrice;
        r.disputeReason = reason;
        r.councilEnd = uint64(block.timestamp + COUNCIL_WINDOW);
        emit SettlementDisputed(market, msg.sender, counterPrice);
        emit DisputeEvidence(market, reason, r.councilEnd);
    }

    function finalize(address market) external nonReentrant {
        Resolution storage r = _resolutions[market];
        if (r.phase != 1 || block.timestamp < r.windowEnd) revert InvalidConfiguration();
        _credit(r.proposer, BOND);
        _finish(market, r.proposedPrice, r.proposer, false);
    }

    /// @notice Each member votes once. No arbitrary third price or unilateral admin override.
    function councilResolve(address market, uint256 price) external nonReentrant {
        Resolution storage r = _resolutions[market];
        uint8 index = councilIndex[msg.sender];
        if (index == 0) revert Unauthorized();
        if (r.phase != 2 || block.timestamp >= r.councilEnd || (price != r.proposedPrice && price != r.counterPrice)) {
            revert InvalidConfiguration();
        }
        uint8 bit = uint8(1 << (index - 1));
        if ((r.votesProposed | r.votesCounter) & bit != 0) revert InvalidConfiguration();
        if (price == r.proposedPrice) r.votesProposed |= bit;
        else r.votesCounter |= bit;
        emit CouncilVote(market, msg.sender, price);
        if (_count(price == r.proposedPrice ? r.votesProposed : r.votesCounter) >= 3) {
            address winner = price == r.proposedPrice ? r.proposer : r.disputer;
            _credit(winner, BOND + BOND / 2);
            // The other half enters insurance before whole-book valuation.
            token.forceApprove(address(vault), BOND / 2);
            vault.donateInsurance(market, BOND / 2);
            _finish(market, price, winner, false);
        }
    }

    /// @notice A council timeout cannot lock users indefinitely. Neither side wins
    /// the bond: both are refunded and the pre-dispute, frozen on-chain TWAP settles.
    function expireDispute(address market) external nonReentrant {
        Resolution storage r = _resolutions[market];
        if (r.phase != 2 || block.timestamp < r.councilEnd) revert InvalidConfiguration();
        _credit(r.proposer, BOND);
        _credit(r.disputer, BOND);
        _finish(market, r.frozenTwap, address(0), true);
    }

    function claimBonds() external nonReentrant {
        uint256 amount = credits[msg.sender];
        if (amount == 0) revert ZeroAmount();
        delete credits[msg.sender];
        token.safeTransfer(msg.sender, amount);
        emit BondClaimed(msg.sender, amount);
    }

    function _receiveBond() private {
        uint256 beforeCash = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), BOND);
        if (token.balanceOf(address(this)) != beforeCash + BOND) revert UnsupportedToken();
    }

    function _credit(address user, uint256 amount) private {
        credits[user] += amount;
        emit BondCredit(user, amount);
    }

    function _finish(address market, uint256 price, address winner, bool timeout) private {
        Resolution storage r = _resolutions[market];
        r.phase = 3;
        r.finalPrice = price;
        Market(market).finalizeResolution(price);
        emit SettlementFinalized(market, price, winner, timeout);
    }

    function _count(uint8 bits) private pure returns (uint8 count) {
        while (bits != 0) {
            count += bits & 1;
            bits >>= 1;
        }
    }
}
