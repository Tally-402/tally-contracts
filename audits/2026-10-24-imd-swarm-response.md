# Response to the IMD swarm audit (2026-10-24)

Report: `2026-10-24-imd-swarm.md` (job `24f0a52b-05e5-4f64-9781-97b23c84b8e3`, commit `24bfa2a`). 6 Low, 3 Info. All nine are valid. Eight are fixed in code with regression tests; finding 9 is a trust assumption, documented and addressed by the mainnet admin plan.

| # | Severity | Finding | Status | Fix | Tests |
|---|---|---|---|---|---|
| 1 | Low | A revoked epoch can't be republished, leaving no live root until the next UTC day | Fixed | `publish` may replace the latest epoch once it is revoked. Each epoch has a `generation`; records keep the generation they were made under, so records under the revoked root stay dead | `ScoreRegistry.t.sol`: `test_CorrectedSnapshotReplacesRevokedToday`, `test_RevertWhen_ReplacingOlderRevokedEpoch` |
| 2 | Low | After a revoke, any older epoch could roll a subject back to an old score | Fixed | Records never move back in time: an epoch older than the last recorded one is always rejected. A revoked record reads as missing until a newer epoch or a corrected snapshot is recorded | `test_AfterRevoke_OlderEpochCannotRollBack` (replaces the old test that allowed the rollback) |
| 3 | Low | The line epoch was a counter, so intents pre-signed for future epochs survived mandate changes | Fixed | `setMandate`, `revokeMandate` and `setAgent` set a fresh epoch from `keccak256(lineId, oldEpoch, prevrandao, timestamp, sender)`. The client already reads the epoch from `getLine`, so no off-chain change | `AuditImd.t.sol`: `test_F3_*` |
| 4 | Low | `liquidate` read `gracePeriod` (and `_roll` read `paymentWindow`) live, so `setParams` retimed issued statements | Fixed | The payment window and grace are fixed when a cycle opens (`cycleWindow`, `cycleGrace`); rolling sets `statementDue` and `liquidatableAt` from them. `liquidate` and `isPastDue` use the stored deadline | `test_F4_*` |
| 5 | Low | Lenders' fee share was donated to the pool in the same transaction, so a same-block deposit could skim it | Fixed | `CreditPool.addYield` (manager only) locks fee income and unlocks it linearly over 24 hours; `totalAssets` excludes the locked part (`unvestedYield`) | `test_F5_*`; `e2e.test.ts` waits a day before checking lender yield |
| 6 | Low | Anyone could deposit into any line or sponsor id, so a front-run `openLine` could capture a deposit | Fixed | `depositCollateral` and `depositSponsorCollateral` are owner only | `test_F6_*` |
| 7 | Info | Fee rounding up could take a whole 1-unit payment | Fixed | `pay` reverts `AmountTooSmall` when the fee would leave the seller nothing | `test_F7_DustPaymentReverts`; fuzz tests updated |
| 8 | Info | Constructors accepted a zero admin; `setEscrow` didn't check the escrow's manager | Fixed | Zero-address checks in all three constructors; `setEscrow` requires `escrow.manager() == this` (`EscrowMismatch`) | `test_F8_*` |
| 9 | Info | Admin powers: grant MANAGER_ROLE and drain idle cash, retune fees and params, arbiter resolves early | Acknowledged | Documented under "Trust assumptions" in `contracts/README.md`. Mainnet: admin is a Safe behind a timelock, and MANAGER_ROLE's admin is renounced after wiring. Finding 4's fix already removes the retroactive part of `setParams` | — |

Test totals after the fixes: 101 contract tests, 33 service tests, all passing. The Base Sepolia deployment predates these fixes and will be redeployed.
