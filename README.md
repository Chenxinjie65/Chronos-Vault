# Chronos Vault

Chronos Vault is a single-asset staking vault for EVM chains. Users stake one ERC20 token into fixed lock tiers, earn rewards based on weighted stake, and pay a penalty for early exit.

The same token is used for both principal and rewards. Admin-funded rewards, early-exit penalties, and forfeited rewards all flow through the same accounting model.

## Status

This repository is implemented and tested as a Foundry project.

- Solidity `^0.8.24`
- Foundry + OpenZeppelin
- single staking token
- multiple positions per user
- fixed lock tiers
- batch claiming
- pause and emergency mode
- deployment script and verification guide

Current test status:

- `61 passed, 0 failed`

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

- [`src/ChronosVault.sol`](/home/cheng/Portfolio/Chronos-Vault/src/ChronosVault.sol): main staking contract
- [`src/interfaces/IChronosVault.sol`](/home/cheng/Portfolio/Chronos-Vault/src/interfaces/IChronosVault.sol): external interface and NatSpec reference
- [`src/MockERC20.sol`](/home/cheng/Portfolio/Chronos-Vault/src/MockERC20.sol): test and local deployment token

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

## Repository layout

```text
src/
  ChronosVault.sol
  MockERC20.sol
  interfaces/IChronosVault.sol
test/
  ChronosVault.t.sol
  MockERC20.t.sol
script/
  DeployChronosVault.s.sol
docs/
  DEPLOYMENT.md
```

## Development

### Prerequisites

- `forge`
- `cast`
- `anvil`

### Install

Clone with submodules:

```bash
git clone --recurse-submodules <repo-url>
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

The repository includes a Foundry deployment script at [`script/DeployChronosVault.s.sol`](/home/cheng/Portfolio/Chronos-Vault/script/DeployChronosVault.s.sol).

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

- see [`docs/DEPLOYMENT.md`](/home/cheng/Portfolio/Chronos-Vault/docs/DEPLOYMENT.md)
- use [`.env.example`](/home/cheng/Portfolio/Chronos-Vault/.env.example) as the local template
- use [`foundry.toml`](/home/cheng/Portfolio/Chronos-Vault/foundry.toml) for RPC and explorer alias configuration

## Test coverage

The current test suite covers:

- weighted reward distribution across different tiers
- reward funding with and without active stakers
- early withdrawal penalty redistribution
- emergency withdrawal forfeiture routing
- pause and emergency mode behavior
- admin configuration paths and revert cases
- helper views and preview semantics
- time and block edge cases
- multiple users and multiple positions

## Scope and limitations

This MVP intentionally does not include:

- upgradeability
- governance
- external yield strategies
- ERC4626 wrappers
- NFT positions
- partial withdrawals
- fee-on-transfer token support
- rebasing token support

## License

MIT
