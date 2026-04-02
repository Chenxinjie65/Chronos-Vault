# Chronos Vault

Chronos Vault is a single-asset staking vault for EVM chains. Users stake one ERC20 token into fixed lock tiers, earn rewards based on weighted stake, and pay a penalty for early exit.

The same token is used for both principal and rewards. Admin-funded rewards, early-exit penalties, and forfeited rewards all flow through the same accounting model.

Supporting docs:

- deployment and verification: [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md)
- audit assumptions and owner powers: [`docs/AUDIT_PREP.md`](docs/AUDIT_PREP.md)
- known issues and design limitations: [`docs/KNOWN_ISSUES.md`](docs/KNOWN_ISSUES.md)

## Core behavior

### Lock tiers

The vault ships with three configured tiers:

- `0`: 30 days, `1.0x` weight
- `1`: 90 days, `1.5x` weight
- `2`: 180 days, `2.0x` weight

Rewards are distributed by weighted stake, not raw principal.

### Reward sources

Rewards can enter the system from:

- owner-funded rewards via `fundRewards`
- penalties charged on early withdrawals
- forfeited rewards from `emergencyWithdraw`

If there are no active stakers when value needs to be distributed, that value is routed to `treasury` instead of being stored for future capture.

### Withdraw paths

- Mature `withdraw` returns principal plus pending rewards.
- Early `withdraw` charges a penalty and redistributes or routes that penalty away from the exiter.
- `emergencyWithdraw` is only available after emergency mode is enabled and returns principal only.

### Pause and emergency semantics

When paused:

- `stake` is disabled
- `claim` and `claimBatch` are disabled
- early `withdraw` is disabled
- mature `withdraw` still works

When emergency mode is enabled:

- it is irreversible for this MVP
- `claim` and `claimBatch` are disabled
- normal `withdraw` is disabled
- users can recover principal with `emergencyWithdraw`

## Contracts

- [`src/ChronosVault.sol`](src/ChronosVault.sol): main staking contract
- [`src/interfaces/IChronosVault.sol`](src/interfaces/IChronosVault.sol): external interface and NatSpec reference
- [`src/MockERC20.sol`](src/MockERC20.sol): test and local deployment token

For integrations, prefer the interface over the concrete implementation ABI.

Useful read methods:

- `getUserPositionIds`
- `getUserActivePositionIds`
- `getPosition`
- `getLockTier`
- `getAllLockTierIds`
- `pendingRewards`
- `previewWithdraw`

Useful write methods:

- `stake`
- `claim`
- `claimBatch`
- `withdraw`
- `emergencyWithdraw`
- `fundRewards`

`previewWithdraw(positionId)` returns:

- `(0, 0, 0)` for missing or withdrawn positions
- principal / reward / penalty for the normal path
- principal only in emergency mode

## Development

### Prerequisites

- `forge`
- `cast`
- `anvil`

### Install

Clone with submodules:

```bash
git clone --recurse-submodules https://github.com/Chenxinjie65/Chronos-Vault.git
cd Chronos-Vault
```

If already cloned without submodules:

```bash
git submodule update --init --recursive
```

### Build

```bash
forge build
```

### Test

```bash
forge test
```

### Format

```bash
forge fmt
```

## Deployment

The repository includes a Foundry deployment script at [`script/DeployChronosVault.s.sol`](script/DeployChronosVault.s.sol).
It also includes an on-chain smoke test script at [`script/SmokeTestChronosVault.s.sol`](script/SmokeTestChronosVault.s.sol).

Quick examples:

Deploy a mock token and vault:

```bash
TREASURY=0x000000000000000000000000000000000000bEEF \
forge script script/DeployChronosVault.s.sol:DeployChronosVaultScript --sig "run()"
```

Deploy a vault using an existing token:

```bash
TREASURY=0x000000000000000000000000000000000000bEEF \
EXISTING_TOKEN=0x000000000000000000000000000000000000c0Fe \
forge script script/DeployChronosVault.s.sol:DeployChronosVaultScript --sig "run()"
```

For environment setup, chain aliases, broadcasting, and block explorer verification:

- see [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md)
- use [`.env.example`](.env.example) as the local template
- use [`foundry.toml`](foundry.toml) for RPC and explorer alias configuration

## Sepolia Deployment

This section is updated after live broadcast and verification.

- MockERC20: `TBD`
- ChronosVault: `TBD`
- Treasury: `TBD`
- Verification:
  - MockERC20: `TBD`
  - ChronosVault: `TBD`

## License

MIT
