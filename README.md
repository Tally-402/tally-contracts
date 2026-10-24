# Tally contracts (v0, secured)

Credit lines ("tabs") for AI agents paying over x402. These are the payment-chain contracts: they deploy on Base first, and later on Solana. The Warden NFTs and the token will live on Ethereum. **Status: prototype. Not audited. Testnet only.**

| Contract | Role |
| --- | --- |
| `CreditPool` | ERC-4626 USDC vault. Depositors get `tpUSDC`. Funds tabs; lent principal stays on the books as `outstanding`. Withdrawals limited to idle cash. |
| `TabManager` | Credit lines, mandates, signed payment intents, weekly billing, repayment, liquidation. |
| `Escrow` | Holds pool-funded payments for larger jobs until delivery is checked. Verifier passes or flags; arbiter rules. |
| `ScoreRegistry` | Ethereum (mirrored on Base). Public Tally Scores: one Merkle root per daily epoch; anyone can verify a score with a proof or record it for other contracts to read with `scoreOf`. |

## How a payment works

1. The owner opens a line for an agent key, deposits USDC collateral and sets a **mandate**: per-payment cap, budget, expiry, optional Merkle allowlist of sellers.
2. The agent signs an EIP-712 `PaymentIntent` (line, epoch, seller, amount, resource hash, escrowed flag, nonce, deadline). Anyone can submit it; normally the Tally facilitator does.
3. `pay` checks the signature (EOA or ERC-1271), epoch, nonce, mandate and credit limit, then:
   - **Direct:** the pool pays the seller at once, minus the seller fee (default 1%, rounded up), and the amount is billed to the open cycle. Half the fee (`poolFeeShareBps`, default 50%, admin-adjustable) goes to the pool, which raises the value of every lender share. The rest accrues for the treasury and is swept with `sweepFees` (pull-based, so a blocked treasury blocks nothing else).
   - **Escrowed:** the pool funds Escrow. The amount is *held*: not billed and not liquidatable until Escrow releases it.
4. **Billing** works like a card statement. A cycle (7 days) opens with the first billable spend. When it closes, its spending becomes the statement, due 3 days later. Two days of grace after that, an unpaid statement can be liquidated by anyone against collateral. Liquidation seizes the whole billable balance (statement plus open cycle). Held amounts settle through Escrow.
5. **Escrow:** the verifier passes (seller paid, amount billed) or flags inside the 1-day review window. Unflagged holds can be claimed by anyone after the window. The arbiter can refund or release flagged holds, and held ones that can't settle (e.g. a blacklisted seller). Flagged holds with no ruling by the deadline set at flag time (7 days) refund automatically.

## Sponsored lines (Tally for Networks)

A sponsor, such as an agent network, deposits collateral once and opens a line for each of its agents:

1. `openSponsor()`, then `depositSponsorCollateral(sponsorId, amount)`.
2. `openSponsoredLine(sponsorId, agent, cap)` for each agent. The sponsor owner owns every line, so it sets each line's mandate with `setMandate` and can rotate agents with `setAgent`.
3. `cap` limits one agent's balance: `NO_CAP` for none, `0` to freeze the line. Change it with `setLineCap`.

Each line keeps its own mandate, statements and Score record. Together, the sponsor's lines can never owe more than its collateral allows; `availableCredit(lineId)` shows what a line can spend after its siblings. Repay line by line with `repay`. A past-due line is liquidated against the sponsor's collateral; the sponsor's other lines keep working. `withdrawSponsorCollateral` releases whatever isn't securing a balance (`sponsorFreeCollateral`).

Things to know: one agent's default reduces the shared collateral for every agent under that sponsor; sibling lines can keep spending until a past-due line is liquidated; sponsor ownership can't be transferred, so a network should own its sponsor from a Safe.

## Safety properties (tested)

- `pool.outstanding` always equals the sum of every line's billed + unbilled + held balance.
- A sponsor's running total always equals the sum of its lines' balances, and never exceeds its collateral.
- Every line's balance stays at or below its collateral (max LTV is capped at 100% in v0).
- TabManager holds exactly the posted collateral (lines and sponsors) plus treasury fees; Escrow holds exactly the open holds.
- Depositors never lose principal in the secured design.
- Intents can't be replayed across chains, contracts, lines or nonces. Changing the mandate or agent key sets a fresh, unpredictable line `epoch`, which kills every intent signed before (including any pre-signed for a guessed future epoch); owners can also cancel a single nonce.
- A statement's due date and grace are fixed when its cycle opens; changing parameters later never retimes it.
- Lenders' fee income unlocks into share value over 24 hours, so a deposit made just before a payment earns nothing from it.
- Only a line's owner (or a sponsor's owner) can deposit its collateral.
- Refunds only restore budget to the mandate the hold was spent under.

101 tests: unit, fuzz (512 runs) and 5 invariants (128 runs × 64 calls). See the audit history below.

## Not in v0 (on purpose)

Interest, unsecured credit, Wardens, staking, slashing, juror panels, the token, upgradeability and a timelock. These come after the Phase 1 gate and a legal review. **Mainnet requires an external audit.**

**Liquidity:** the pool never lends more than `maxUtilizationBps` (90%) of its assets, so lenders always keep a withdrawal buffer.

Known limitations: liquidation has no keeper reward, so Tally runs a keeper. The verifier and arbiter are trusted roles in v0 (an offline verifier lets unchecked holds release after the review window).

**Trust assumptions.** "Depositors never lose principal" holds as long as the admin key is honest:
- CreditPool's admin can grant `MANAGER_ROLE` to any address, and a manager can send idle cash anywhere with `fund` (up to the utilization cap).
- TabManager's admin sets the treasury, the fee split, LTV and billing parameters (new cycles only), and wires the escrow once.
- Escrow's arbiter can resolve a hold at any time.

On mainnet the admin is a Safe behind a timelock, and `MANAGER_ROLE`'s admin is renounced once TabManager is wired, so no key can add a manager.

## Audit history

| Date | Review | Result |
| --- | --- | --- |
| 2026-10-22 | Internal review agent | 3 Medium, 5 Low; all fixed with regression tests |
| 2026-10-23 | Independent review of sponsored lines | 0 High, 0 Medium, 1 Low (a cap of 0 removed the cap instead of freezing the line); fixed with a regression test |
| 2026-10-22 | pashov solidity-auditor v4.1, 1 pass, 12 agents | 3 findings (confidence 75), 16 leads; all 3 findings fixed, 7 leads addressed. Report: `audits/2026-10-22-pashov-solidity-auditor.md` |
| 2026-10-24 | IMD agent swarm (4 specialists and a judge, each finding reproduced) | 0 High, 0 Medium, 6 Low, 3 Info; 8 fixed with regression tests, 1 trust assumption documented. Report and response: `audits/2026-10-24-imd-swarm.md`, `audits/2026-10-24-imd-swarm-response.md` |

## Develop

```
cd contracts
mkdir -p lib
git clone --depth 1 --branch v5.1.0 https://github.com/OpenZeppelin/openzeppelin-contracts lib/openzeppelin-contracts
git clone --depth 1 --branch v1.9.4 https://github.com/foundry-rs/forge-std lib/forge-std
forge build
forge test
```

## ScoreRegistry

The Score engine publishes one Merkle root per epoch (the UTC day number) with `publish`. Each leaf is one payer's score and its five components, hashed in the OpenZeppelin StandardMerkleTree format with the epoch included, so a proof only works for its own epoch.

- **Verify:** `verify(epoch, leaf, proof)` is a free view call.
- **Record:** `record(epoch, leaf, proof)` stores a proven score; then `scoreOf(subject)` returns it with its `asOf` time. Anyone can record. Records only move forward in time, even after a revoke; check `asOf` against your own freshness limit.
- **Revoke:** the admin can withdraw a bad snapshot. Its proofs stop verifying and its recorded scores read as missing; an older valid score can then be recorded.
- **Safety:** epochs only move forward and can't be later than today, so a leaked publisher key can't block future snapshots. If the admin revokes the latest snapshot, the publisher can replace it the same day; scores recorded under the revoked root stay dead. The admin can rotate the publisher.

Proofs come from the Score API (`GET /proof/:address`) or the snapshot file at the epoch's `uri`.

```
export ADMIN=<address>  PUBLISHER=<Score publisher address>
forge script script/DeployScoreRegistry.s.sol --rpc-url $SEPOLIA_RPC --account deployer --broadcast
```

## Deployments

| Network | Contracts | Addresses |
| --- | --- | --- |
| Base Sepolia | CreditPool, TabManager, Escrow, ScoreRegistry | `deployments/base-sepolia.json` (repo root) |
| Ethereum Sepolia | All | Blocked for now, see below |

**Glamsterdam and contract size.** Since Glamsterdam went live on Sepolia (2026-10-06), storing contract code costs far more gas (EIP-8037; the proposal lists 1,530 gas per byte, up from 200). Foundry's local simulation still uses the old price, so its gas estimates are too low and creations run out of gas. TabManager (about 20 KB) would need roughly 30M gas, above the 16.8M per-transaction cap, so it must be split before it can deploy on Ethereum (Sepolia now, mainnet once Glamsterdam ships). The smaller contracts fit, but deploy them with node-side estimation (`--skip-simulation --slow`) or check with `cast estimate --create` first. Base Sepolia is unaffected for now.

## Deploy (testnets)

Payment contracts go to Base (per-call payments) and, as a test setup for job-sized work with Ethereum-native networks, to Ethereum. ScoreRegistry goes to Ethereum, with a mirror on Base.

```
export ADMIN=<your address>  TREASURY=<address>  VERIFIER=<address>  DEPOSIT_CAP=10000000000

# 1. Payment contracts on Base Sepolia (Circle USDC; verify on basescan first)
USDC=0x036CbD53842c5426634e7929541eC2318f3dCF7e \
  forge script script/Deploy.s.sol --rpc-url $BASE_SEPOLIA_RPC --account deployer --broadcast

# 2. Payment contracts on Ethereum Sepolia (Circle USDC; verify on etherscan first)
USDC=0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238 \
  forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC --account deployer --broadcast

# 3. ScoreRegistry on Ethereum Sepolia, and its mirror on Base Sepolia
export PUBLISHER=<Score publisher address>
forge script script/DeployScoreRegistry.s.sol --rpc-url $SEPOLIA_RPC --account deployer --broadcast
forge script script/DeployScoreRegistry.s.sol --rpc-url $BASE_SEPOLIA_RPC --account deployer --broadcast
```

Use a Foundry keystore (`cast wallet import deployer --interactive`). Never put private keys in `.env` or in chat.

## License

The payment contracts (CreditPool, TabManager, Escrow and their interfaces) are under the Business Source License 1.1: anyone can read, audit, test and build on them for non-production use, and they become MIT on 2030-10-23. ScoreRegistry, the tests, mocks and scripts are MIT. See `LICENSE`.
