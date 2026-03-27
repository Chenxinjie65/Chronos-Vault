# Known Issues And Limitations

This document lists the current Chronos Vault MVP limitations that should be disclosed to users, integrators, and auditors.

These items are not all "bugs" in the strict sense. They are grouped as:

- accepted design limitations
- operator trust assumptions
- compatibility and integration limitations

The list is based on the current implementation in [`src/ChronosVault.sol`](/home/cheng/Portfolio/Chronos-Vault/src/ChronosVault.sol) and the current project specification in [`SPEC.md`](/home/cheng/Portfolio/Chronos-Vault/SPEC.md).

## Summary Of The Three User-Raised Items

| ID | Item | Verdict | Notes |
| --- | --- | --- | --- |
| KI-01 | A user can stake before `fundRewards` and share that funding round | Accepted design limitation, but should be disclosed clearly | This is an economic fairness limitation of instant, event-driven reward funding rather than a reward-accounting bug. |
| KI-02 | A user who stakes and exits entirely between two `fundRewards` calls may receive no owner-funded rewards | Accepted design limitation, but should be disclosed clearly | Rewards are discrete-event based, not time-streamed. |
| KI-03 | Integer division can leave token dust in the vault | Accepted design limitation per `SPEC.md` | Rounding stays conservative, but a small residual token balance can remain. |

## Accepted Design Limitations

### KI-01: Reward funding can be stake-sniped right before `fundRewards`

Status: accepted design limitation

Relevant code:

- [`src/ChronosVault.sol:86`](/home/cheng/Portfolio/Chronos-Vault/src/ChronosVault.sol#L86)
- [`src/ChronosVault.sol:132`](/home/cheng/Portfolio/Chronos-Vault/src/ChronosVault.sol#L132)
- [`src/ChronosVault.sol:431`](/home/cheng/Portfolio/Chronos-Vault/src/ChronosVault.sol#L431)

Why it exists:

- `stake()` mints reward entitlement from the current accumulator snapshot only.
- `fundRewards()` immediately distributes the full `amount` across whatever `totalWeightedStaked` exists at execution time.
- There is no cooldown, epoch snapshot, or time-weighted vesting before a new position can share a funding round.

Impact:

- If a reward-funding transaction is visible in the mempool, a user can stake just before it lands and capture a share of that reward round.
- The highest-weight tier can increase the size of that capture.
- If the reward round is large enough, an opportunistic user may still profit even after paying the early-exit penalty.

Why this is treated as acceptable for the MVP:

- The vault uses a simple accumulator model with discrete funding events.
- The current spec requires conservative accounting and zero-staker safety, but it does not require time-vested or anti-MEV reward distribution.

If this becomes unacceptable:

- use streaming emissions instead of lump-sum funding
- add epoch snapshots
- add a minimum staking age before a position shares owner-funded rewards
- fund through private order flow instead of the public mempool

### KI-02: No owner-funded rewards accrue between discrete funding events

Status: accepted design limitation

Relevant code:

- [`src/ChronosVault.sol:132`](/home/cheng/Portfolio/Chronos-Vault/src/ChronosVault.sol#L132)
- [`src/ChronosVault.sol:400`](/home/cheng/Portfolio/Chronos-Vault/src/ChronosVault.sol#L400)
- [`src/ChronosVault.sol:431`](/home/cheng/Portfolio/Chronos-Vault/src/ChronosVault.sol#L431)

Why it exists:

- Rewards are created only when value is pushed into the accumulator.
- In the current MVP, that happens through:
  - `fundRewards()`
  - early-withdraw penalty redistribution
  - forfeited rewards from `emergencyWithdraw()`
- There is no per-second or per-block emission schedule.

Impact:

- A user who stakes after one funding round and exits before the next one may receive zero owner-funded rewards.
- Users should not interpret the vault as a continuous APY product.
- Time spent staked matters only if a distribution event happens while the position is active.

Why this is treated as acceptable for the MVP:

- It is consistent with the implemented accounting model.
- It keeps the contract simple and makes all reward creation explicit on-chain.

Disclosure requirement:

- Frontends and docs should describe rewards as event-driven, not continuously accruing yield.

### KI-03: Integer division creates conservative rounding dust

Status: accepted design limitation

Relevant code:

- [`src/ChronosVault.sol:400`](/home/cheng/Portfolio/Chronos-Vault/src/ChronosVault.sol#L400)
- [`src/ChronosVault.sol:405`](/home/cheng/Portfolio/Chronos-Vault/src/ChronosVault.sol#L405)
- [`src/ChronosVault.sol:431`](/home/cheng/Portfolio/Chronos-Vault/src/ChronosVault.sol#L431)
- [`SPEC.md:447`](/home/cheng/Portfolio/Chronos-Vault/SPEC.md#L447)

Why it exists:

- The accumulator and reward-debt math use integer division.
- Each distribution round is rounded down.
- Each position's realized claim is also rounded down.

Impact:

- Small residual token dust can remain in the contract.
- Some dust may become claimable after later reward rounds, but exact full exhaustion is not guaranteed.
- The current contract has no explicit dust-sweep function.

Why this is treated as acceptable for the MVP:

- The spec explicitly allows conservative rounding dust.
- The current implementation does not over-distribute rewards.

Important note:

- This is acceptable only as long as stakeholders understand that exact token-perfect exhaustion is not guaranteed.

### KI-04: Direct token transfers and residual dust are not automatically accounted or sweepable

Status: accepted limitation, should be disclosed

Relevant code:

- [`src/ChronosVault.sol:86`](/home/cheng/Portfolio/Chronos-Vault/src/ChronosVault.sol#L86)
- [`src/ChronosVault.sol:132`](/home/cheng/Portfolio/Chronos-Vault/src/ChronosVault.sol#L132)
- [`src/ChronosVault.sol`](/home/cheng/Portfolio/Chronos-Vault/src/ChronosVault.sol)

Why it exists:

- The contract only accounts for value that enters through its explicit flows.
- A plain ERC20 transfer sent directly to the vault address does not update the accumulator or any position state.
- There is no owner rescue or sweep function for stray staking-token balance.

Impact:

- Accidental token transfers to the vault can become stuck.
- Rounding dust can remain as unallocated extra balance.
- Integrators should not assume `stakingToken.balanceOf(vault)` equals "claimable rewards".

Why this is acceptable for the MVP:

- It avoids hidden admin drain paths.
- It keeps the accounting surface small and explicit.

## Operator Trust Assumptions

### KI-05: The owner can change the early-exit penalty for existing positions

Status: trust assumption, not a code bug

Relevant code:

- [`src/ChronosVault.sol:335`](/home/cheng/Portfolio/Chronos-Vault/src/ChronosVault.sol#L335)

Impact:

- The owner can raise or lower `earlyExitPenaltyBps` at any time, up to `MAX_EARLY_EXIT_PENALTY_BPS`.
- Existing positions are not grandfathered into the penalty that existed when they staked.
- Users therefore take owner-policy risk for the entire life of their position.

Why this is acceptable for the MVP:

- The spec explicitly allows owner-controlled capped updates.
- The cap of 30% limits, but does not remove, policy risk.

Recommended disclosure:

- Users should understand that early-exit terms are not immutable for already-open positions.

### KI-06: The owner can permanently enable emergency mode and force principal-only recovery

Status: trust assumption, not a code bug

Relevant code:

- [`src/ChronosVault.sol:76`](/home/cheng/Portfolio/Chronos-Vault/src/ChronosVault.sol#L76)
- [`src/ChronosVault.sol:255`](/home/cheng/Portfolio/Chronos-Vault/src/ChronosVault.sol#L255)
- [`src/ChronosVault.sol:302`](/home/cheng/Portfolio/Chronos-Vault/src/ChronosVault.sol#L302)

Impact:

- Once emergency mode is enabled, normal `withdraw()` is disabled.
- Users can recover principal through `emergencyWithdraw()`, but they forfeit pending rewards.
- This can materially change user outcomes even for positions that were close to maturity.

Why this is acceptable for the MVP:

- The spec explicitly defines emergency mode as irreversible principal-recovery mode.
- This is an operational safety lever, not a hidden admin drain.

Recommended disclosure:

- Users should treat emergency mode as an admin-controlled override that prioritizes principal recovery over reward continuity.

### KI-07: Zero-staker routed value is treasury-controlled, and the owner can change `treasury`

Status: trust assumption, not a code bug

Relevant code:

- [`src/ChronosVault.sol:137`](/home/cheng/Portfolio/Chronos-Vault/src/ChronosVault.sol#L137)
- [`src/ChronosVault.sol:346`](/home/cheng/Portfolio/Chronos-Vault/src/ChronosVault.sol#L346)
- [`src/ChronosVault.sol:415`](/home/cheng/Portfolio/Chronos-Vault/src/ChronosVault.sol#L415)

Impact:

- Rewards funded during zero-staker periods, last-staker penalties, and zero-staker forfeited rewards all go to `treasury`.
- The owner can repoint `treasury` to a different address.
- Users therefore trust the operator on where zero-staker value ultimately lands.

Why this is acceptable for the MVP:

- Treasury routing is required by the spec to prevent zero-staker windfalls.
- The remaining trust surface is governance/operations, not accounting correctness.

## Compatibility And Integration Limitations

### KI-08: The vault assumes a standard ERC20 and does not support fee-on-transfer, rebasing, or callback-heavy tokens

Status: compatibility limitation

Relevant code:

- [`src/ChronosVault.sol:127`](/home/cheng/Portfolio/Chronos-Vault/src/ChronosVault.sol#L127)
- [`src/ChronosVault.sol:146`](/home/cheng/Portfolio/Chronos-Vault/src/ChronosVault.sol#L146)
- [`docs/AUDIT_PREP.md`](/home/cheng/Portfolio/Chronos-Vault/docs/AUDIT_PREP.md)

Impact:

- Fee-on-transfer tokens would break the assumption that the requested transfer amount equals the received amount.
- Rebasing tokens would make internal accounting diverge from external balances.
- Exotic callback behavior is outside the intended MVP compatibility set.

Why this is acceptable for the MVP:

- The repository already documents standard-ERC20 assumptions.
- Supporting these token classes would materially expand complexity and testing surface.

### KI-09: Position helper and batch flows scale linearly with the number of positions

Status: gas and UX limitation

Relevant code:

- [`src/ChronosVault.sol:176`](/home/cheng/Portfolio/Chronos-Vault/src/ChronosVault.sol#L176)
- [`src/ChronosVault.sol:242`](/home/cheng/Portfolio/Chronos-Vault/src/ChronosVault.sol#L242)

Impact:

- `getUserActivePositionIds()` loops over every recorded position for a user.
- `claimBatch()` loops over every supplied position id.
- Heavy users with many positions may face expensive calls or need to manage claims off-chain more carefully.

Why this is acceptable for the MVP:

- The product intentionally supports multiple positions without introducing NFT wrappers or more complex indexing structures.
- The implementation prefers explicitness over advanced gas-optimized bookkeeping.

## What Is Not Being Classified As A Known Issue Here

The following behaviors are considered intended protocol behavior rather than issues:

- zero-staker reward, penalty, and forfeiture routing to `treasury`
- early-exit redistribution excluding the exiting position
- mature withdrawals remaining available while paused
- emergency withdrawals returning principal only

Those behaviors should still be reviewed in a formal audit, but they are core design requirements rather than documented limitations.
