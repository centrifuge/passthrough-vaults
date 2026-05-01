// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice FIFO queue state for a single investor in one direction (deposit or redeem)
struct QueuePosition {
    uint128 rangeStart; /// global queue index at which this investor's segment begins
    uint128 pending;    /// amount currently in this investor's queue segment (assets or shares, depending on direction)
}

library QueueLib {
    function claimable(QueuePosition storage pos, uint128 settled) internal view returns (uint128) {
        if (pos.pending == 0) return 0;
        if (settled <= pos.rangeStart) return 0;
        uint128 available = settled - pos.rangeStart;
        return pos.pending > available ? available : pos.pending;
    }

    /// @dev Place the combined position (any unsettled remainder + new amount) at the back of the
    ///      global queue. The tail advances by the new amount only; the unsettled remainder is carried
    ///      forward without re-expanding the queue. Any previously unsettled portion leads to a segment
    ///      of orphaned units and an equal segment of overlapping units in the queue. The orphaned units
    ///      will eventually become claimable for this controller once settlement passes the overlap,
    ///      causing only a delay for this controller with no disadvantage to others.
    function enqueue(QueuePosition storage pos, uint128 amount, uint128 tail) internal returns (uint128 newTail) {
        pos.rangeStart = tail - pos.pending;
        pos.pending += amount;
        return tail + amount;
    }

    function claim(QueuePosition storage pos, uint128 amount) internal {
        pos.rangeStart += amount;
        pos.pending -= amount;
    }
}
