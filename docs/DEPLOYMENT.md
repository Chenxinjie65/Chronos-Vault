# Deployment and Verification

This repository is designed to deploy cleanly to standard EVM chains with Foundry and to verify source code on common block explorers.

The project already includes a deployment script:

- [`script/DeployChronosVault.s.sol`](/home/cheng/Portfolio/Chronos-Vault/script/DeployChronosVault.s.sol)

That script supports two modes:

- deploy a new [`MockERC20`](/home/cheng/Portfolio/Chronos-Vault/src/MockERC20.sol) and then deploy [`ChronosVault`](/home/cheng/Portfolio/Chronos-Vault/src/ChronosVault.sol)
- reuse an existing ERC20 token and deploy only the vault

## 1. What the script expects

Script-controlled variables:

- `TREASURY`: required; recipient for zero-staker routed value
- `EXISTING_TOKEN`: optional; if non-zero, the vault uses this ERC20
- `DEPLOY_MOCK`: optional; defaults to `true` when `EXISTING_TOKEN` is unset
- `MOCK_NAME`: optional mock token name
- `MOCK_SYMBOL`: optional mock token symbol
- `MOCK_INITIAL_SUPPLY`: optional initial mock mint amount

Foundry CLI variables:

- `PRIVATE_KEY`: used by `forge script --broadcast --private-key ...`
- `..._RPC_URL`: RPC endpoint for the chain you want to deploy to
- explorer API key variables such as `ETHERSCAN_API_KEY`, `BASESCAN_API_KEY`, or `ARBISCAN_API_KEY`

The repository includes a copyable template at [`.env.example`](/home/cheng/Portfolio/Chronos-Vault/.env.example).

## 2. Create your local config

Create a local environment file:

```bash
cp .env.example .env
```

Then fill in the values you need. Example for Sepolia using an existing token:

```bash
TREASURY=0x1234567890123456789012345678901234567890
EXISTING_TOKEN=0xabcdefabcdefabcdefabcdefabcdefabcdefabcd
DEPLOY_MOCK=false
PRIVATE_KEY=YOUR_PRIVATE_KEY
SEPOLIA_RPC_URL=https://sepolia.infura.io/v3/YOUR_KEY
ETHERSCAN_API_KEY=YOUR_ETHERSCAN_KEY
```

Load the environment into your shell before running deployment commands:

```bash
source .env
```

## 3. Optional Foundry chain aliases

Foundry is easiest to use when you define chain aliases in `foundry.toml`. You can either pass raw RPC URLs on the command line, or add an alias section like this to your local `foundry.toml`:

```toml
[rpc_endpoints]
sepolia = "${SEPOLIA_RPC_URL}"
base_sepolia = "${BASE_SEPOLIA_RPC_URL}"
arbitrum_sepolia = "${ARBITRUM_SEPOLIA_RPC_URL}"

[etherscan]
sepolia = { key = "${ETHERSCAN_API_KEY}" }
base_sepolia = { key = "${BASESCAN_API_KEY}" }
arbitrum_sepolia = { key = "${ARBISCAN_API_KEY}" }
```

Notes:

- do not commit real RPC URLs or real API keys
- this section is only needed for alias-based commands like `--rpc-url sepolia` or automatic `--verify`
- if your explorer is Blockscout rather than Etherscan-compatible, keep using `--rpc-url` and verify manually with `--verifier blockscout`

## 4. Dry-run before broadcasting

Always run a dry-run first:

Deploy with a mock token:

```bash
source .env

forge script script/DeployChronosVault.s.sol:DeployChronosVaultScript \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --sig "run()"
```

Deploy using an existing token:

```bash
source .env

forge script script/DeployChronosVault.s.sol:DeployChronosVaultScript \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --sig "run()"
```

The script reads `TREASURY`, `EXISTING_TOKEN`, `DEPLOY_MOCK`, and mock settings from the environment. It prints the deployed contract addresses to the console.

## 5. Broadcast a real deployment

Once the dry-run looks correct, broadcast the transactions:

Using explicit RPC URL:

```bash
source .env

forge script script/DeployChronosVault.s.sol:DeployChronosVaultScript \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --sig "run()" \
  -vvvv
```

Using a chain alias configured in `foundry.toml`:

```bash
source .env

forge script script/DeployChronosVault.s.sol:DeployChronosVaultScript \
  --rpc-url sepolia \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --sig "run()" \
  -vvvv
```

After broadcasting, Foundry writes deployment receipts to:

```text
broadcast/DeployChronosVault.s.sol/<chain-id>/run-latest.json
```

That file is the canonical record of:

- the deployed addresses
- the transaction hashes
- the broadcaster address
- the constructor inputs used by the script

## 6. Automatic explorer verification during deploy

For Etherscan-compatible explorers, the smoothest path is to let Foundry verify during the deployment run:

```bash
source .env

forge script script/DeployChronosVault.s.sol:DeployChronosVaultScript \
  --rpc-url sepolia \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --verify \
  --sig "run()" \
  -vvvv
```

This requires:

- a matching `[etherscan]` entry in your local `foundry.toml`
- the correct explorer API key in your environment
- a chain alias that matches the explorer entry name

When this path works, Foundry will submit source verification for the deployed contracts automatically after broadcasting.

## 7. Manual verification on a block explorer

If automatic verification is unavailable or you are using a non-standard explorer, verify each contract manually.

### 7.1 ChronosVault verification

The vault constructor is:

```solidity
constructor(address stakingToken_, address treasury_)
```

Build the constructor arguments:

```bash
VAULT_CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,address)" "$STAKING_TOKEN" "$TREASURY")
```

Verify on an Etherscan-compatible explorer:

```bash
forge verify-contract \
  --chain sepolia \
  --watch \
  --constructor-args "$VAULT_CONSTRUCTOR_ARGS" \
  <VAULT_ADDRESS> \
  src/ChronosVault.sol:ChronosVault
```

Verify on a Blockscout-style explorer:

```bash
forge verify-contract \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --verifier blockscout \
  --verifier-url "$BLOCKSCOUT_VERIFIER_URL" \
  --etherscan-api-key "$BLOCKSCOUT_API_KEY" \
  --watch \
  --constructor-args "$VAULT_CONSTRUCTOR_ARGS" \
  <VAULT_ADDRESS> \
  src/ChronosVault.sol:ChronosVault
```

### 7.2 MockERC20 verification

Only needed when you actually deployed the mock token.

The mock constructor is:

```solidity
constructor(string memory name_, string memory symbol_, address initialHolder_, uint256 initialSupply_)
```

The `initialHolder_` is the broadcaster address. You can derive it from the deployment key:

```bash
DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY")
```

Encode the constructor arguments:

```bash
MOCK_CONSTRUCTOR_ARGS=$(cast abi-encode \
  "constructor(string,string,address,uint256)" \
  "$MOCK_NAME" \
  "$MOCK_SYMBOL" \
  "$DEPLOYER" \
  "$MOCK_INITIAL_SUPPLY")
```

Then verify:

```bash
forge verify-contract \
  --chain sepolia \
  --watch \
  --constructor-args "$MOCK_CONSTRUCTOR_ARGS" \
  <MOCK_TOKEN_ADDRESS> \
  src/MockERC20.sol:MockERC20
```

## 8. Recommended post-deploy checklist

After deployment and verification:

1. confirm the token address in the vault matches the expected ERC20
2. confirm the treasury address is correct
3. confirm the owner is the expected deployer or admin wallet
4. confirm the source code shows as verified on the explorer
5. fund rewards with a small test amount before any public use
6. make a small stake and claim on the target chain before wider rollout

## 9. Common mistakes

- forgetting to `source .env`, which leaves `TREASURY` or `PRIVATE_KEY` unset
- setting both `EXISTING_TOKEN` and `DEPLOY_MOCK=true` and expecting the mock path to win; the script intentionally prefers `EXISTING_TOKEN`
- trying to use `--verify` without adding the matching `[etherscan]` config
- verifying with the wrong constructor arguments
- verifying the mock token with the wrong `initialHolder_`; it is the broadcaster, not the treasury
- deploying to an explorer network that has a different chain alias name than your local `foundry.toml`

## 10. Minimal command reference

Dry-run:

```bash
forge script script/DeployChronosVault.s.sol:DeployChronosVaultScript \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --sig "run()"
```

Broadcast:

```bash
forge script script/DeployChronosVault.s.sol:DeployChronosVaultScript \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --sig "run()"
```

Broadcast and verify:

```bash
forge script script/DeployChronosVault.s.sol:DeployChronosVaultScript \
  --rpc-url sepolia \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --verify \
  --sig "run()"
```
