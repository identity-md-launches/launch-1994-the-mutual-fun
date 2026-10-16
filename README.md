# The mutual fun (TMF)

A fixed-supply ERC-20 token for the IdentityMD custom-token launch on Robinhood Chain.

| Parameter | Value |
|---|---|
| Solidity contract | `MutualFunToken` (`src/MutualFunToken.sol`) |
| Token name | `The mutual fun` |
| Token symbol | `TMF` |
| Decimals | 18 |
| Total supply | 1,000,000,000 TMF = `1000000000000000000000000000` minor units |
| Minting | Once, in the constructor, all to `msg.sender` (the deployer) |
| Constructor arguments | None |
| Owner / admin | None |
| Compiler | solc 0.8.26, optimizer on (200 runs), `bytecode_hash = "none"` |

## What the contract does

`MutualFunToken` inherits OpenZeppelin's `ERC20` (v5.4.0, vendored under `lib/`) and adds nothing
but constants and a constructor. The constructor mints the entire supply to `msg.sender` and
there is no other code path that creates tokens. The contract has:

- no owner, no roles, no `Ownable` and no `transferOwnership`;
- no `mint`, `burn`, `burnFrom`, `pause`, blacklist, freeze, seize or transfer toggle;
- no fee, tax or reflection on transfer: every transfer moves exactly the amount requested;
- no proxy, `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`;
- no `receive`/`fallback`, so it refuses ether.

After deployment nobody, including the deployer, can change its behaviour or touch any balance
other than their own (or an allowance a holder granted them through standard `approve`).

## Assumptions

- The brief asks only for name, symbol and a fixed 1,000,000,000 supply minted to the deployer.
  No burn, tax, vesting or governance was requested, so none is implemented. Supply can therefore
  never grow and never shrink.
- The deployer at launch is the IdentityMD `ProjectFactory`. The factory receives the whole supply
  and distributes it (swarm share, pool seed, remainder); the token itself allocates nothing.
- The constructor calls no other contract and depends on no chain state, so it deploys on an
  empty chain and under CREATE2 from any address.
- Robinhood Chain is an EVM L2. The token uses no `block.number`, `block.timestamp`, `chainid`
  or signature logic, so no L2 execution difference affects it.

## Deployment parameters (for the launch manifest)

These are the values the manifest step records. They are documented here, not written to a
`launch.json`, which is the manifest step's to produce.

- `token.contract`: `MutualFunToken`
- `token.name`: `The mutual fun`
- `token.symbol`: `TMF`
- `token.decimals`: `18`
- `token.constructorArgs`: `[]`
- `token.totalSupply`: `1000000000000000000000000000`
- Application contracts: none
- Chain: Robinhood Chain (chain id 4663)
- Pool pair: IMD (`0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127`), fee 12500 (1.25%), tick spacing 60
- Economics (copied from the job by the manifest step):
  `poolBps` 8000, `initialMarketCapWei` 3200 IMD (`3200000000000000000000`),
  `remainderTo` `0x12a7aad083cef06fef7c295514b52fc8bc81960d`

Supply split performed by the factory at launch:

| Share | Recipient | Amount (TMF) |
|---|---|---|
| 10% | Launch MerkleDistributor (swarm) | 100,000,000 |
| 80% | Uniswap v4 pool seed (single-sided) | 800,000,000 |
| 10% | `remainderTo` (the requester) | 100,000,000 |

## After launch

Nothing to configure. The token has no owner-settable values, no external dependencies and no
privileged functions. There are no post-launch steps.

## Operational responsibilities

- **Requester / holders.** Custody of balances is entirely the holder's. Tokens sent to a wrong
  address, to the token contract itself, or to `address(0)` via a third-party contract cannot be
  recovered: there is no admin to intervene.
- **Allowances.** Standard ERC-20 approvals apply. Infinite approvals (`type(uint256).max`) are
  not decremented; holders should approve only what a spender needs.
- **Liquidity.** The pool is opened and seeded by IdentityMD's deployer at the price derived from
  the market cap above. Liquidity management after launch is outside this contract.
- **Explorer verification.** The launch deploys the attested creation code. Verifying the source
  on the chain explorer is the deployer's step, with the compiler settings in `foundry.toml`.
- **Security review.** Tests passing is not an audit. The contract is a thin wrapper over an
  audited library, but an independent adversarial review before release remains good practice.

## Repository layout

```
foundry.toml                      compiler pins and remappings
src/MutualFunToken.sol            the token
script/DeployMutualFunToken.s.sol reference deploy script (local use; the launch deploys itself)
test/MutualFunToken.t.sol         success, failure, fuzz and launch-flow tests
lib/forge-std                     Foundry test library v1.11.0 (vendored, no submodule)
lib/openzeppelin-contracts        OpenZeppelin v5.4.0, only the files ERC20 needs (vendored)
```

## Build and test

```
forge build
forge test
forge fmt --check
```

Tests read no environment variables and pass in any order and in parallel. The fuzz tests were
run with the verifier's seed:

```
FOUNDRY_FUZZ_SEED=0x8c33f8e6e88ba84dfa0c5eb1a08e7d8ed44265462e8bd75d5bdf76a633ea992f forge test
```

## Tests

`test/MutualFunToken.t.sol` covers:

- metadata and constants match the brief; the supply is minted once, to the deployer, with a
  `Transfer` event from the zero address;
- CREATE2 deployment from a factory stand-in lands the supply on the factory at the predicted
  address, and deployment from a code-less address on an empty chain succeeds;
- transfers and `transferFrom` move exact amounts, emit events, and preserve the supply;
- failure paths: insufficient balance (including one unit above), transfer to the zero address,
  missing or insufficient allowance, approval of the zero spender;
- launch flows: the 10% swarm share, a claim out of the distributor, and the 10% remainder each
  arrive whole, leaving exactly the 80% pool share on the factory;
- no mint, owner, pause, blacklist, burnFrom or upgrade selector exists; the deployer cannot
  move a holder's balance; the contract refuses ether; the runtime contains no `DELEGATECALL`,
  `CALLCODE` or `SELFDESTRUCT` and fits EIP-170;
- fuzz: transfers conserve the supply, over-balance transfers revert, `transferFrom` within an
  allowance decrements it, and no random call from any caller changes the total supply;
- the deploy script's `deploy()` function mints to its caller.

## Licence

MIT. OpenZeppelin Contracts is MIT (see `lib/openzeppelin-contracts/LICENSE`); forge-std is
MIT/Apache-2.0 (see `lib/forge-std`).
