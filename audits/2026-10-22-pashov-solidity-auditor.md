<!-- Report of the pashov solidity-auditor skill (v4.1), 1 pass, 12 Sonnet agents, on commit 3dd5fcb. Findings were fixed in the following commit; see contracts/README.md "Audit history". -->

# 🔐 Security Review — contracts

---

## Scope

|  |  |
| --- | --- |
| **Mode** | default |
| **Files reviewed** | `./src/Escrow.sol` · `./src/CreditPool.sol` · `./src/TabManager.sol`<br>`./script/Deploy.s.sol` |
| **Confidence threshold (1-100)** | 75 |

---

## Findings

[75] **1. One borrower can lend out all idle pool cash and block withdrawals**

`CreditPool.fund` · Confidence: 75

**Description**
Any line owner with enough collateral can draw all idle USDC, so no depositor can withdraw until the tab is repaid or liquidated.

**Fix**

```diff
     function fund(address to, uint256 amount) external onlyRole(MANAGER_ROLE) {
         uint256 cash = idle();
         if (amount > cash) revert InsufficientIdle(amount, cash);
+        if ((outstanding + amount) * BPS > totalAssets() * maxUtilizationBps) revert UtilizationCap();
         outstanding += amount;
```

---

[75] **2. An admin change to rulingWindow moves the deadline of flagged holds**

`Escrow.setWindows` · Confidence: 75

**Description**
The `expire` function reads the current `rulingWindow`, so after an admin change any caller can refund a flagged hold before the arbiter rules.

**Fix**

```diff
-        h.flaggedAt = uint64(block.timestamp);
+        h.rulingEndsAt = uint64(block.timestamp + rulingWindow);
 ...
-        if (block.timestamp <= uint256(h.flaggedAt) + rulingWindow) revert RulingOpen();
+        if (block.timestamp <= h.rulingEndsAt) revert RulingOpen();
```

---

[75] **3. Pay lets one line take all pool cash for a 1% fee**

`TabManager.pay` · Confidence: 75

**Description**
A line owner pays a seller address that they own with all idle USDC, so depositors cannot withdraw for about 12 days.

**Fix**

```diff
         _roll(l);
         _checkCredit(l, p.amount);
+        // A utilization cap in CreditPool.fund bounds what one line can draw.
+        // Route part of the seller fee to the pool so lenders earn from lent cash.
```

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [75] | One borrower can lend out all idle pool cash and block withdrawals |
| 2 | [75] | An admin change to rulingWindow moves the deadline of flagged holds |
| 3 | [75] | Pay lets one line take all pool cash for a 1% fee |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **A direct USDC transfer fills the deposit cap** — `CreditPool.maxDeposit` — Code smells: `totalAssets` reads `balanceOf`; `maxDeposit` compares it to `depositCap` — Any account can send USDC to the pool until `totalAssets` reaches the cap, so every deposit reverts until the admin raises the cap. The donor loses the USDC to existing holders, so we did not find a profitable path.
- **Early lenders can leave later lenders with a loss** — `CreditPool.maxWithdraw` — Code smells: withdrawals use `idle()` while `outstanding` stays at full value — Lenders who exit first leave any later loss to those who stay. No loss path exists at 100% LTV.
- **The deploy script uses msg.sender as the temporary admin** — `Deploy.run` — Code smells: `address deployer = msg.sender;` after `vm.startBroadcast()` with `--account` and no `--sender` — If Foundry sets `msg.sender` to its default sender, the wiring calls revert and the deployment fails. We did not run the script with a keystore.
- **A blocked seller or treasury makes every release of a hold fail** — `Escrow._release` — Code smells: `_release` pushes USDC to the seller and then to `manager.treasury()` — If USDC blocks the seller or the treasury, `pass`, `claim` and a release ruling revert, and the collateral stays locked until the arbiter refunds or the admin changes the treasury.
- **An offline verifier lets every hold release without a check** — `Escrow.claim` — Code smells: only the verifier can flag; `claim` opens to any caller after `reviewEndsAt` — If the verifier is offline for one review window, every hold releases to its seller and the owner owes the full amount. We did not find a way for an outsider to force the outage.
- **A seller that cannot receive USDC leaves the hold to the arbiter** — `Escrow.claim` — Code smells: `claim` and `pass` revert on the seller transfer; the owner has no refund path — Only the arbiter can end the hold, so the owner's collateral stays locked if the arbiter does not act.
- **The ruling deadline follows the live rulingWindow** — `Escrow.expire` — Code smells: `expire` checks `h.flaggedAt + rulingWindow` with the current value — An admin change moves the deadline of every open flagged hold, earlier or later than the parties expected.
- **A silent arbiter makes expire refund the buyer** — `Escrow.expire` — Code smells: `expire` refunds a flagged hold after the ruling window with no check of the delivery — If the arbiter does not rule in time, any caller refunds the buyer, even when the seller delivered.
- **Settlement of a blocked hold depends on the arbiter** — `Escrow.resolve` — Code smells: only `resolve(true)` from ARBITER_ROLE clears a hold whose release reverts — Until the arbiter acts, `held` stays on the line and the collateral stays locked.
- **The refund-to-owner path is unreachable** — `TabManager.creditRefund` — Code smells: `toOwner` is always 0; `claimRefund` pays from the balance that also holds collateral — A future change that lets `held` fall below a hold would let `claimRefund` pay from collateral. We found no path today.
- **Any caller can bill a hold just before liquidation** — `TabManager.onRelease` — Code smells: `claim` is open to any caller; `liquidate` seizes `unbilled` too — A caller releases a hold seconds before `liquidate`, so the owner has no time to repay that amount. The line is already in default, so we did not find a changed outcome.
- **onRelease bills the line with no limit check** — `TabManager.onRelease` — Code smells: no `whenNotPaused`, no `nonReentrant`, no credit check — The hook is safe only while collateral covers `held`. We found no sequence that breaks this.
- **The agent chooses whether a payment goes through escrow** — `TabManager.pay` — Code smells: `p.escrowed` is a free field in the signed intent; the mandate has no escrow threshold — The agent can pay any amount directly, so the verifier never checks the delivery. This is a design choice for the owner.
- **The seller fee rounds down to zero on small payments** — `TabManager.pay` — Code smells: `fee = (p.amount * sellerFeeBps) / BPS` rounds down — A payment under 100 base units pays no fee to the treasury at 100 bps. We did not find that splitting payments pays off after gas.
- **The pool earns nothing for lent cash** — `TabManager.pay` — Code smells: the seller fee goes to `treasury`; `repay` returns principal only — Lenders carry the lock-up and default risk for no return. This is a design question, and we found no code defect.
- **A blocked treasury makes every direct payment fail** — `TabManager.pay` — Code smells: `pay` pushes the fee to `treasury` in the same transaction — If USDC blocks the treasury address, every direct payment reverts until the admin calls `setTreasury`. This needs the token issuer to block the treasury.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
