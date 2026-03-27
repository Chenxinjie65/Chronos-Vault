# Known Issues And Limitations

This note lists the main Chronos Vault MVP limitations that users, integrators, and auditors should know.

## Design Limitations

- `fundRewards` is event-driven, so a user can stake right before an owner funding transaction and share that round. This is an economic fairness limitation, not a reward-accounting bug.
- Owner-funded rewards are not time-streamed. A position that is opened and closed entirely between two `fundRewards` calls may receive no owner-funded rewards at all.
- Integer division in the accumulator and reward-debt math can leave small token dust in the vault. The rounding is conservative, but exact zero-dust exhaustion is not guaranteed.
- Direct ERC20 transfers to the vault are not incorporated into reward accounting. Stray tokens or residual dust can remain stuck because there is no sweep path in the MVP.

## Trust Assumptions

- The owner can change `earlyExitPenaltyBps` for already-open positions, up to the configured cap. Users therefore take penalty-policy risk for the full lifetime of their stake.
- The owner can irreversibly enable emergency mode. After that, users can only recover principal with `emergencyWithdraw` and must forfeit pending rewards.
- Rewards, penalties, and forfeited rewards created during zero-staker periods are routed to `treasury`, and the owner can update the treasury address. That behavior is intentional for zero-staker safety, but it is still an operator trust assumption.

## Compatibility Limits

- The vault assumes a standard ERC20. Fee-on-transfer, rebasing, and callback-heavy tokens are out of scope and may break accounting assumptions.
- User-position helper and batch flows scale linearly with the number of positions. Heavy users may face higher gas costs or need more off-chain indexing support.
