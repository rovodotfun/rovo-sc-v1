# Rovo

**Rovo Smart Contracts — Robinhood Chain**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.28-363636.svg)](https://soliditylang.org/)
[![Chain](https://img.shields.io/badge/Chain-Robinhood-CCFF00.svg)](https://chain.robinhood.com/)
[![Website](https://img.shields.io/badge/Website-rovo.fun-black.svg)](https://rovo.fun)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](./#contributing)

[![OpenZeppelin](https://img.shields.io/badge/OpenZeppelin-Contracts-4E5EE4.svg)](https://github.com/OpenZeppelin/openzeppelin-contracts)
[![Pons](https://img.shields.io/badge/Pons-V2-111111.svg)](https://docs.ponsfamily.com/v2)

<p align="center">
  <img src="media/logo.svg" alt="Rovo" width="220" />
</p>

This repository holds the Solidity source for **[rovo.fun](https://rovo.fun)** — a Social-RWA launchpad on Robinhood Chain.

Rovo launches profile markets via **Pons Protocol V2**, pairs them against Robinhood Stock Tokens, and routes the Pons creator allocation (plus creator tax) through a unique per-launch fee collector into creators, Rovers, holders, and a platform sink. Scout launches escrow unclaimed creator fees in the **Nottingham Vault** until the real X owner claims.

Website: [rovo.fun](https://rovo.fun)

## Table of contents

- [What Rovo adds](#what-rovo-adds)
- [Launch flow](#launch-flow)
- [Fee model](#fee-model)
- [Core contracts](#core-contracts)
- [Stack](#stack)
- [Repository layout](#repository-layout)
- [Dependencies](#dependencies)
- [Design notes](#design-notes)
- [Security](#security)
- [Documentation](#documentation)
- [Contributing](#contributing)
- [License](#license)
- [Attribution](#attribution)

## What Rovo adds

Most social launchpads pay attention. Rovo pays in Stock Tokens — and Scout & Claim lets anyone open a market for a public handle before the owner arrives.

| Surface | Behavior |
| --- | --- |
| Launch venue | Pons V2 bonding curve → Uniswap V4 (via Pons) |
| Quote assets | Robinhood Stock Tokens (allowlisted by Pons) |
| Who launches | Self-Rove (verified owner) or Scout (anyone for an unclaimed handle) |
| Fee custody | Unique `LaunchFeeCollector` per profile token |
| Who earns | Creator (or Nottingham), Rover (scout), holders, platform reservoir |
| Claim path | EIP-712 attested claim → delay → finalize into creator control |
| Zap path | Native/WETH → Stock Token → curve or post-grad V4 buy |
| Treasury route | Admin may divert a claim batch to treasury instead of the on-chain split |

## Launch flow

Rovo does not reinvent bonding curves. It wraps Pons launches, pins fee recipients, and keeps identity + fee routing honest.

1. **`launchSelfRove` / `launchScout`** (+ optional `AndBuy`) — verify EIP-712 attestation, CREATE2-clone a fee collector, call Pons `launchToken` / `launchAndBuy` with that collector as `creatorFeeRecipient`, register the launch.
2. **Curve trading** — trades settle on Pons; creator allocation + creator tax credit Pons FeeEscrow for the collector.
3. **`harvest` / `collect`** — splitter (or admin batch) claims escrow into the collector and disperses along the launch-type split.
4. **Scout claim** — real X owner initiates with an identity attestation, waits `claimDelay`, then `finalizeClaim` marks the registry and releases Nottingham balance.

Deterministic collector preview: `LaunchFeeCollectorFactory.predict(launchKey, wrapper)`.

## Fee model

Rovo receives only the **Pons creator allocation plus creator tax**. Pons protocol fees are out of scope. Fees are always in the launch's quote / pair asset (Stock Token or native).

When the **normal split** runs (`collect` → `disperse`):

| Launch type | Platform | Creator / vault | Rover | Holders |
| --- | --- | --- | --- | --- |
| Self-Rove | 10% | 70% to creator | — | 20% (+ optional share from creator bucket) |
| Scout (unclaimed) | 10% | 60% to Nottingham Vault | 15% | 15% |
| Scout (claimed) | 10% | 60% to creator | 15% | 15% (+ optional share from creator bucket) |

**Scout sunset (60 days, still unclaimed):** the 60% creator bucket splits 50/50 into holders and platform instead of remaining in Nottingham.

**Treasury route:** `LaunchFeeCollector.collectToTreasury` (admin only) sends the full claimable amount for that batch to the configured treasury. Mutually exclusive with the normal split for the amount claimed in that transaction.

Hard caps on launch: Self-Rove creator tax **100–500 bps**; Scout uses the wrapper's immutable scout tax in the same range.

## Core contracts

### Launch and identity

| Contract | Role |
| --- | --- |
| [`RovoFactoryWrapper.sol`](src/RovoFactoryWrapper.sol) | Entry point: Self-Rove / Scout launches, attestations, opening buys |
| [`RovoRegistry.sol`](src/RovoRegistry.sol) | Launch records, handle / `xUserId` uniqueness, claim + share flags |
| [`LaunchFeeCollectorFactory.sol`](src/LaunchFeeCollectorFactory.sol) | Deterministic clone factory for per-launch collectors |
| [`LaunchFeeCollector.sol`](src/LaunchFeeCollector.sol) | Pons FeeEscrow recipient; `collect` or `collectToTreasury` |
| [`RovoTypes.sol`](src/RovoTypes.sol) | Shared `Launch` / `LaunchType` definitions |

### Fees and rewards

| Contract | Role |
| --- | --- |
| [`RovoFeeSplitter.sol`](src/RovoFeeSplitter.sol) | Harvest, disperse BPS splits, pending withdraw for wallets |
| [`NottinghamVault.sol`](src/NottinghamVault.sol) | Scout creator escrow + EIP-712 claim lifecycle |
| [`HolderRewardDistributor.sol`](src/HolderRewardDistributor.sol) | Per-token Stock Token pools + Merkle epoch claims |
| [`PlatformFeeReservoir.sol`](src/PlatformFeeReservoir.sol) | Platform fee custody for buyback / ops executors |

### Trading helpers

| Contract | Role |
| --- | --- |
| [`RovoZapRouter.sol`](src/RovoZapRouter.sol) | Zap into Stock Token then buy on curve or bound V4 adapter |
| [`UniswapV3StockAdapter.sol`](src/UniswapV3StockAdapter.sol) | Allowlisted ETH/WETH → Stock Token via Uniswap V3 |

### Interfaces

- [`interfaces/IPonsV2.sol`](src/interfaces/IPonsV2.sol)
- [`interfaces/IRovoModules.sol`](src/interfaces/IRovoModules.sol)
- [`interfaces/IRovoRegistry.sol`](src/interfaces/IRovoRegistry.sol)

## Stack

| Item | Value |
| --- | --- |
| Language | Solidity `0.8.28` |
| Chain | Robinhood Chain (EVM L2, chain ID `4663`) |
| Product | [rovo.fun](https://rovo.fun) |
| Launch / liquidity | [Pons Protocol V2](https://docs.ponsfamily.com/v2) (curve + Uniswap V4 graduation) |
| Access control | OpenZeppelin `AccessControl`, EIP-712 attestations |
| Safety | OpenZeppelin `ReentrancyGuard`, `SafeERC20`, `Pausable` |
| Zap venue | Uniswap V3 (Stock Token adapter) |

## Repository layout

```text
.
├── README.md
├── LICENSE
├── media/
│   ├── logo.svg
│   └── wordmark.svg
├── docs/
│   ├── contracts.md      # Per-contract API and privilege notes
│   └── fee-routing.md    # Collector → splitter → buckets / treasury
└── src/
    ├── RovoFactoryWrapper.sol
    ├── RovoRegistry.sol
    ├── LaunchFeeCollector.sol
    ├── LaunchFeeCollectorFactory.sol
    ├── RovoFeeSplitter.sol
    ├── NottinghamVault.sol
    ├── HolderRewardDistributor.sol
    ├── PlatformFeeReservoir.sol
    ├── RovoZapRouter.sol
    ├── UniswapV3StockAdapter.sol
    ├── RovoTypes.sol
    └── interfaces/
```

This repository ships **first-party source**. Foundry tests, deploy scripts, and vendored dependencies live outside this tree so the public surface stays reviewable.

## Dependencies

Contracts compile against:

- **OpenZeppelin Contracts** — AccessControl, EIP712, ECDSA, ERC20 / SafeERC20, ReentrancyGuard, Pausable, Clones, MerkleProof
- **Pons V2** — factory, launch-and-buy, FeeEscrow (consumers via [`IPonsV2.sol`](src/interfaces/IPonsV2.sol))
- **Uniswap V3** — factory + SwapRouter02 (adapter only)

Wire those packages (or a verified vendor tree) before compiling. Do not treat this folder as a complete Foundry workspace on its own.

## Design notes

- **Pons owns the market.** Rovo does not deploy custom curves or lock LP; it sets fee recipients and identity gates.
- **One collector per launch.** Pons FeeEscrow balances are keyed by recipient + asset. Sharing a recipient would merge revenue across launches.
- **Fees stay in quote.** Splitter and buckets credit the launch pair token — never memecoin dust as protocol revenue.
- **Scout is escrow-first.** Unclaimed creator share sits in Nottingham until claim (or 60-day sunset redistribution).
- **Treasury is explicit.** Admins choose normal split vs `collectToTreasury` per claim batch; both cannot apply to the same claimed amount.
- **Adapter boundary.** Zap only talks to allowlisted `IRovoSwapAdapter` implementations; V4 adapters are bound per graduated token.
- **Attestations expire fast.** Launch and claim EIP-712 payloads are capped at a 10-minute lifetime and nonces are single-use.

## Security

- Launch, harvest, claim, zap, and withdraw paths use `ReentrancyGuard` where funds move; token transfers use `SafeERC20`.
- Identity for Self-Rove, Scout, and Nottingham claims is EIP-712 signed by `IDENTITY_SIGNER_ROLE`.
- Handle hash and `xUserId` are unique in `RovoRegistry` for the life of a launch.
- Creators cannot mint supply, upgrade Pons markets, or redirect another launch's collector.
- `NottinghamVault` is pausable; claim finalization requires the configured delay after initiation.
- Keepers / epoch publishers hold scoped roles only — no blanket owner keys on user funds paths.

This repository ships source only. Verify deployed bytecode against verified explorer sources before trusting a live address.

If you find a security issue, please report it privately instead of opening a public issue. Contact details are on [rovo.fun](https://rovo.fun).

## Documentation

- [`docs/contracts.md`](docs/contracts.md) — function-level privilege summary
- [`docs/fee-routing.md`](docs/fee-routing.md) — fee flow, BPS tables, treasury and sunset rules

## Contributing

Issues and pull requests are welcome. Prefer focused diffs, clear commit messages, and discussion before large architectural changes.

## License

First-party Rovo contracts: **MIT** (see [`LICENSE`](./LICENSE) and SPDX headers).

Upstream licenses remain as marked per file:

- OpenZeppelin sources: MIT
- Pons / Uniswap interfaces: upstream licenses as marked by those projects

## Attribution

Bonding-curve launches, graduation, and on-curve / hook fee collection are provided by [Pons Protocol V2](https://docs.ponsfamily.com/v2). Rovo's factory wrapper, fee collectors, splitter, Nottingham Vault, holder rewards, reservoir, and zap stack are original.

If this project is useful to you, consider starring the repository.
