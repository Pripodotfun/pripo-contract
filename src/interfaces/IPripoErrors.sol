// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IPripoErrors {
    error Slippage(uint256 wanted, uint256 got);
    error OICapExceeded(uint256 cap, uint256 attempted);
    error StaleOracle(uint64 age);
    error InsufficientMargin(uint256 have, uint256 need);
    error NotLiquidatable(int256 health);
    error PolicyViolation(uint8 code);
    error ZeroAmount();
    error InvalidReserves();
    error ReserveExhausted();
    error ZeroQuote();
    error MathOverflow();
    error InvalidLeverage(uint256 leverage);
    error InvalidBps(uint256 bps);
    error InvalidSize();
    error InvalidFundingParameters();
    error AccountingInvariant();
    error TimeWentBackwards(uint64 previousBlock, uint64 currentBlock);
    error Unauthorized();
    error InvalidAddress();
    error InvalidConfiguration();
    error DepositCapExceeded();
    error UnsupportedToken();
    error InvalidReferral();
    error InsufficientInsurance(uint256 have, uint256 need);
    error UncoveredBadDebt(uint256 remaining);
    error MarketNotActive();
    error UnexpectedValue();
    error InvalidOracle();
    error OracleConfidence(uint16 confidenceBps);
    error PositionExists();
    error NoPosition();
    error UpgradeNotReady();
}
