# Chronos Vault

Chronos Vault is a single-asset staking vault for EVM chains. Users stake one ERC20 token into fixed lock tiers, earn rewards based on weighted stake, and pay a penalty for early exit.

The same token is used for both principal and rewards. Admin-funded rewards, early-exit penalties, and forfeited rewards all flow through the same accounting model.

This repository is built as a compact staking-protocol MVP and a reviewable engineering sample. The implementation emphasizes conservative accounting, clear failure modes, and testable reward logic instead of protocol sprawl.

## Portfolio Highlights

- principal accounting is kept separate from weighted reward accounting
- zero-staker rewards, penalties, and forfeited rewards are routed away from future-capture edge cases
- users can hold multiple concurrent positions with independent lock tiers
- the project includes unit, fuzz, and invariant tests plus a verified Sepolia deployment and live smoke test

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

Deployed on `2026-04-02` to Sepolia (`chainId 11155111`).

- MockERC20: [`0x78e95ee9d64a480Fdf4F7B0766212B36a2d83388`](https://sepolia.etherscan.io/address/0x78e95ee9d64a480fdf4f7b0766212b36a2d83388)
- ChronosVault: [`0xb18A48A6211697e01a5738e9bD64aC875532FC9e`](https://sepolia.etherscan.io/address/0xb18a48a6211697e01a5738e9bd64ac875532fc9e)
- Treasury: `0xeefbF82D8f5e9149036A9136876EfeE72a3b65AE`
- Verification status: both contracts verified on Etherscan
- MockERC20 deploy tx: [`0xb27a4d1ce84eeb67e29a1c4170a4a1ee487b82083290dd646afbeec21cdf534b`](https://sepolia.etherscan.io/tx/0xb27a4d1ce84eeb67e29a1c4170a4a1ee487b82083290dd646afbeec21cdf534b)
- ChronosVault deploy tx: [`0xfd39d51aaead8a5752c221accc52323138ec7c0eed0b45036d3ab7be9c8d46bf`](https://sepolia.etherscan.io/tx/0xfd39d51aaead8a5752c221accc52323138ec7c0eed0b45036d3ab7be9c8d46bf)
- Smoke test `approve` tx: [`0x544dbd0514a8e5002a99b1e3638c9032cbfcddc1a3451a71104672b6d6d8f07b`](https://sepolia.etherscan.io/tx/0x544dbd0514a8e5002a99b1e3638c9032cbfcddc1a3451a71104672b6d6d8f07b)
- Smoke test `stake` tx: [`0x98587760d6eeeb0367640a5094a534aeadc7794bc362f9d2f899b6f85fb1209b`](https://sepolia.etherscan.io/tx/0x98587760d6eeeb0367640a5094a534aeadc7794bc362f9d2f899b6f85fb1209b)
- Smoke test `fundRewards` tx: [`0x040cbecf93fadfc859ffac29b61780e2b2cdae74d208e25cf465fb509f2df854`](https://sepolia.etherscan.io/tx/0x040cbecf93fadfc859ffac29b61780e2b2cdae74d208e25cf465fb509f2df854)
- Smoke test `claim` tx: [`0xc4b4de9a582503c2c8297816ca45d1dff17bed57727802a6bf467319cdd0d169`](https://sepolia.etherscan.io/tx/0xc4b4de9a582503c2c8297816ca45d1dff17bed57727802a6bf467319cdd0d169)

## License

MIT
