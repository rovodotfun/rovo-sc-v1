# Fee routing

How Rovo-controlled revenue moves from Pons FeeEscrow into wallets and buckets.

## End-to-end flow

```text
Trade on Pons curve / graduated pool
        │
        ▼
Pons protocol fee (out of scope)
        │
        ▼
Creator allocation + creator tax
        │
        ▼
Pons FeeEscrow[LaunchFeeCollector]
        │
        ├── collect() ──────────────► RovoFeeSplitter.disperse(...)
        │                                   │
        │                                   ├── platform BPS → PlatformFeeReservoir
        │                                   ├── creator / vault BPS → wallet or Nottingham
        │                                   ├── rover BPS → rover wallet (Scout)
        │                                   └── holders BPS → HolderRewardDistributor
        │
        └── collectToTreasury() ────► splitter.treasury()  (admin route; no on-chain split)
```

## Normal split (BPS of claimed amount)

Constants: `BPS = 10_000`. Base platform cut is always **1_000 bps (10%)**.

### Self-Rove

| Bucket | BPS | Destination |
| --- | ---: | --- |
| Platform | 1_000 | `PlatformFeeReservoir` |
| Holders (base) | 2_000 | `HolderRewardDistributor` |
| Creator | 7_000 | Creator pending balance (minus optional share) |

If `shareWithHolders` is enabled, `creatorToHoldersBps` of the **creator bucket** is added to holders.

### Scout — unclaimed

| Bucket | BPS | Destination |
| --- | ---: | --- |
| Platform | 1_000 | `PlatformFeeReservoir` |
| Rover | 1_500 | Rover pending balance |
| Holders | 1_500 | `HolderRewardDistributor` |
| Creator | 6_000 | `NottinghamVault` |

### Scout — claimed

Same BPS as unclaimed Scout, but the 6_000 creator bucket credits the **claimed creator** wallet (with optional `shareWithHolders` from that bucket), not Nottingham.

### Scout sunset

If still unclaimed and `block.timestamp >= launchedAt + 60 days`, the 6_000 creator bucket is **not** sent to Nottingham:

- half → holders
- half → platform

Rover and base holder cuts are unchanged.

### Dust

Any BPS rounding remainder is added to the holders bucket so the full claimed amount is accounted.

## Treasury route

`LaunchFeeCollector.collectToTreasury`:

1. Caller must hold `DEFAULT_ADMIN_ROLE` on the splitter (`bytes32(0)`).
2. Collector claims the full available FeeEscrow balance for its quote asset.
3. Entire amount transfers to `RovoFeeSplitter.treasury`.
4. No `disperse` call — creator, Rover, holders, Nottingham, and reservoir receive **nothing** from that batch on-chain.

Use cases: audit-period ops, off-app creator payments, or other manual allocation. Product surfaces should disclose when this route is in use.

## Why unique collectors

Pons FeeEscrow balances are keyed by **recipient + asset**, not by launched token. Reusing one recipient across launches would merge claimable balances for the same Stock Token. Every Rovo launch therefore clones its own collector and binds the profile token after Pons returns the address.

## Withdrawals and claims

- **Creator / Rover wallets:** `RovoFeeSplitter.withdraw(asset)` pulls pending credits.
- **Nottingham:** `initiateClaim` (EIP-712) → wait `claimDelay` → `finalizeClaim` transfers vault balance and marks the registry claimed.
- **Holders:** epoch publisher posts Merkle root; holders `claim` with proofs against `HolderRewardDistributor`.
- **Platform:** executor role releases reservoir balances for buyback / ops off this tree's scope.
