// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {TabManager} from "./TabManager.sol";

/// @title TabLens
/// @notice Read-only views over TabManager: statements, past-due status and credit limits. Holds no funds and
///         no state of its own; it exists to keep TabManager under the contract-size limit.
contract TabLens {
    TabManager public immutable tabs;
    uint16 internal constant BPS = 10_000;

    constructor(TabManager tabs_) {
        tabs = tabs_;
    }

    /// @notice The line's statement as it stands now, including a cycle that has closed but not rolled.
    function statementOf(uint256 lineId)
        public
        view
        returns (uint256 billed, uint256 unbilled, uint256 held, uint256 dueAt, uint256 cycleEnd)
    {
        TabManager.Line memory l = tabs.getLine(lineId);
        billed = l.billed;
        unbilled = l.unbilled;
        held = l.held;
        dueAt = l.statementDue;
        cycleEnd = l.cycleEnd;
        if (cycleEnd != 0 && block.timestamp >= cycleEnd) {
            if (unbilled > 0) {
                billed += unbilled;
                unbilled = 0;
                if (dueAt == 0) dueAt = cycleEnd + l.cycleWindow;
            }
            cycleEnd = 0;
        }
    }

    /// @notice True once the line can be liquidated.
    function isPastDue(uint256 lineId) external view returns (bool) {
        TabManager.Line memory l = tabs.getLine(lineId);
        (uint256 billed,,, uint256 dueAt,) = statementOf(lineId);
        uint256 at = l.statementDue != 0 ? l.liquidatableAt : dueAt + l.cycleGrace;
        return billed > 0 && block.timestamp > at;
    }

    /// @notice Most the line could owe right now: own collateral times LTV, or for a sponsored line the
    ///         sponsor's limit (shared with its other lines) capped by the line's own cap.
    function creditLimit(uint256 lineId) public view returns (uint256) {
        uint256 sid = tabs.sponsorOf(lineId);
        uint256 ltv = tabs.maxLtvBps();
        if (sid == 0) return (uint256(tabs.getLine(lineId).collateral) * ltv) / BPS;
        uint256 limit = (uint256(tabs.getSponsor(sid).collateral) * ltv) / BPS;
        uint256 cap = tabs.lineCap(lineId);
        return cap < limit ? cap : limit;
    }

    /// @notice What the line can spend now. For sponsored lines this accounts for the sponsor's other lines.
    function availableCredit(uint256 lineId) external view returns (uint256) {
        uint256 out = tabs.outstandingOf(lineId);
        uint256 sid = tabs.sponsorOf(lineId);
        uint256 ltv = tabs.maxLtvBps();
        if (sid == 0) {
            uint256 limit = (uint256(tabs.getLine(lineId).collateral) * ltv) / BPS;
            return limit > out ? limit - out : 0;
        }
        TabManager.Sponsor memory s = tabs.getSponsor(sid);
        uint256 sLimit = (uint256(s.collateral) * ltv) / BPS;
        uint256 avail = sLimit > s.outstanding ? sLimit - s.outstanding : 0;
        uint256 cap = tabs.lineCap(lineId);
        if (cap != tabs.NO_CAP()) {
            uint256 capAvail = cap > out ? cap - out : 0;
            if (capAvail < avail) avail = capAvail;
        }
        return avail;
    }
}
