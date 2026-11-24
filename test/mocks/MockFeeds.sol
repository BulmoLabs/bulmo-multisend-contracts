// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Chainlink-style feed whose answer, timestamps and decimals tests can set freely.
/// Used as a price feed (answer = price) or as an L2 sequencer uptime feed (answer 0 = up, 1 = down).
contract MockAggregator {
    uint8 public decimals;
    string public description = "ETH / USD";
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        answer = answer_;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
    }

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function setStartedAt(uint256 startedAt_) external {
        startedAt = startedAt_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, startedAt, updatedAt, 1);
    }
}
