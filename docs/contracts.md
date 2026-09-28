# Contract reference

Privilege and responsibility notes for first-party Rovo contracts. For fee math see [`fee-routing.md`](./fee-routing.md).

## `RovoFactoryWrapper`

**Role:** Public launch entry point. Verifies EIP-712 Self-Rove / Scout attestations, clones a `LaunchFeeCollector`, calls Pons `launchToken` / `launchAndBuy`, binds the collector to the new profile token, and registers the launch.

| Caller | Functions |
| --- | --- |
| Anyone (with valid attestation) | `launchSelfRove`, `launchSelfRoveAndBuy`, `launchScout`, `launchScoutAndBuy` |
| `DEFAULT_ADMIN_ROLE` | Role grants only (constructor-wired immutables) |
| `IDENTITY_SIGNER_ROLE` | Signs launch attestations off-chain (not an on-chain call) |

**Notes:** Creator tax must be 100–500 bps (Self-Rove arg; Scout uses immutable `scoutCreatorTaxBps`). Pair token must be Pons-approved. Opening-buy quote recipient is always `msg.sender` for Pons tax alignment.

## `RovoRegistry`

**Role:** Canonical launch record store. Enforces one token per handle hash and per `xUserId`.

| Caller | Functions |
| --- | --- |
| `LAUNCHER_ROLE` (wrapper) | `registerLaunch` |
| `CLAIM_FINALIZER_ROLE` (Nottingham) | `markClaimed` |
| Claimed creator | `setShareWithHolders` |
| Anyone | `getLaunch`, `handleToToken`, `xUserIdToToken` |

## `LaunchFeeCollectorFactory`

**Role:** Deterministic EIP-1167 clone factory for collectors.

| Caller | Functions |
| --- | --- |
| `WRAPPER_ROLE` | `create` |
| Anyone | `predict` |

## `LaunchFeeCollector`

**Role:** Unique Pons `creatorFeeRecipient` per launch. Claims FeeEscrow then either disperses via splitter or sends to treasury.

| Caller | Functions |
| --- | --- |
| Wrapper | `initialize`, `bindProfileToken` |
| Splitter | `collect` |
| Splitter `DEFAULT_ADMIN_ROLE` | `collectToTreasury` |

**Notes:** `collect` and `collectToTreasury` both pull the same escrow balance for that call — choose one route per claim batch.

## `RovoFeeSplitter`

**Role:** Harvest collectors and apply launch-type BPS splits into wallets and buckets.

| Caller | Functions |
| --- | --- |
| `DEFAULT_ADMIN_ROLE` | `harvest`, `harvestBatch` |
| Bound fee collector | `disperse` |
| Credited wallet | `withdraw` |

Immutables: registry, Nottingham, holder rewards, reservoir, treasury address (used by collectors for the treasury route).

## `NottinghamVault`

**Role:** Holds Scout creator share until claim. Two-phase claim with delay.

| Caller | Functions |
| --- | --- |
| Splitter | `credit` |
| Anyone (valid attestation) | `initiateClaim` |
| Anyone (after delay) | `finalizeClaim` |
| `DEFAULT_ADMIN_ROLE` | `setSplitter` (once) |
| `PAUSER_ROLE` | `pause` / `unpause` |
| `IDENTITY_SIGNER_ROLE` | Signs claim attestations off-chain |

## `HolderRewardDistributor`

**Role:** Credits holder fee share per profile token; publishers post Merkle epochs; holders claim with proofs.

| Caller | Functions |
| --- | --- |
| Splitter | `credit` |
| `EPOCH_PUBLISHER_ROLE` | `setEpochRoot` |
| Anyone with valid proof | `claim` |
| `DEFAULT_ADMIN_ROLE` | `setSplitter` (once), role grants |

## `PlatformFeeReservoir`

**Role:** Custody for the platform BPS slice until an executor releases it.

| Caller | Functions |
| --- | --- |
| Splitter | `credit` |
| `EXECUTOR_ROLE` | `release` (or equivalent executor pull) |
| `DEFAULT_ADMIN_ROLE` | `setSplitter` (once), role grants |

## `RovoZapRouter`

**Role:** Convert an input asset into the launch pair token, then buy on the Pons curve (pre-grad) or a bound V4 adapter (post-grad). May request Pons `createGraduatedPool`.

| Caller | Functions |
| --- | --- |
| Anyone | `buyCurve`, post-grad buy helpers, graduation request helpers |
| `DEFAULT_ADMIN_ROLE` | `setAdapter`, `setV4Adapter` |

**Notes:** Only allowlisted adapters; V4 adapter must be set per graduated profile token after phase confirmation.

## `UniswapV3StockAdapter`

**Role:** `IRovoSwapAdapter` that swaps native/WETH into an admin-configured Stock Token via a verified Uniswap V3 pool.

| Caller | Functions |
| --- | --- |
| Zap router (as caller of `swapExactInput`) | Swap execution |
| `DEFAULT_ADMIN_ROLE` | Configure stock token fees / pools |

## `RovoTypes`

Library-only shared enums/structs (`LaunchType`, `Launch`). No privileges.
