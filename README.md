# Bulmo Multisend: smart contracts

[![License: MIT](https://img.shields.io/badge/license-MIT-8B2CF5)](LICENSE)
[![Solidity 0.8.28](https://img.shields.io/badge/solidity-0.8.28-363636)](foundry.toml)
[![Built with Foundry](https://img.shields.io/badge/built%20with-Foundry-FFDB1C)](https://getfoundry.sh)
[![Tests: 179 passing](https://img.shields.io/badge/tests-179%20passing-2EA043)](test)
[![Coverage: 100%](https://img.shields.io/badge/coverage-100%25-2EA043)](#security)
[![Bytecode: reproducible](https://img.shields.io/badge/bytecode-reproducible-19F0FF)](#verify-the-deployed-code-yourself)

**Bulmo Multisend** sends native coins or ERC-20 tokens to up to 500 wallets in a single transaction. Use it for airdrops, payroll, contributor rewards and token distributions on **Ethereum, BNB Chain, Base, Arbitrum, HyperEVM, Robinhood Chain and Elysium**, at the same contract address on every chain.

This repository holds the complete, verified source code of the deployed contracts, their tests and the tools to prove the deployed code matches this source.

**[Open the app](https://app.bulmo.xyz)** · **[Website](https://bulmo.xyz)** · **[Security review](SECURITY_REVIEW.md)** · **[Deployments (JSON)](deployments.json)** · **[Deploy guide](docs/DEPLOYING.md)**

## Highlights

- **One transaction, up to 500 recipients.** Native coin (ETH, BNB, HYPE) or any ERC-20 token, including USDT-style and fee-on-transfer tokens.
- **Free for small sends.** Up to 5 wallets per transaction is free. Larger sends pay a flat fee per transaction, set in US dollars.
- **Non-custodial.** Tokens move straight from the sender to each recipient. The contracts never hold user funds, and any overpayment is refunded in the same transaction.
- **All-or-nothing.** If any single transfer fails, the whole transaction reverts. Nobody is half-paid.
- **No upgrades, no pause, no proxy.** The deployed code can never change. Fee caps can only go down.
- **Personal Multisend.** A one-time purchase gives you your own multisend contract with no fees, for you and up to 5 team wallets.

## Fees

| Recipients per transaction | Fee (paid in the chain's native coin at the live USD price) |
| --- | --- |
| 1 to 5 | Free |
| 6 to 20 | $10 |
| 21 to 50 | $19 |
| 51 to 500 | $49 |
| Personal Multisend (unlimited sends, no fees) | $49 once per chain |

Prices are converted with Chainlink price feeds. Elysium has no Chainlink feed yet, so only free sends (1 to 5 wallets) are open there for now. The contract enforces a hard cap of **$100 per transaction** and a native-coin cap; both can only be lowered, never raised. You sign a maximum, the contract charges the live fee and refunds the rest in the same transaction.

## Deployed contracts

The same addresses on all seven chains, deployed with CREATE2:

| Contract | Address |
| --- | --- |
| `BulmoMultisend` (pay per send) | `0xEF37b4902AD3eDc923112BD47C0D776bd2A419B3` |
| `BulmoMultisendFactory` (sells Personal Multisends) | `0xC90079E3C00671B13a8f85d2FC2c9E9A0F3305D9` |
| `BulmoPersonalMultisend` (clone implementation) | `0xFd5602187ce9Cd6c53C8469BBB518eBe913b2896` |

| Chain | Chain ID | BulmoMultisend | Factory | Clone implementation |
| --- | --- | --- | --- | --- |
| Ethereum | 1 | [etherscan.io](https://etherscan.io/address/0xEF37b4902AD3eDc923112BD47C0D776bd2A419B3) | [etherscan.io](https://etherscan.io/address/0xC90079E3C00671B13a8f85d2FC2c9E9A0F3305D9) | [etherscan.io](https://etherscan.io/address/0xFd5602187ce9Cd6c53C8469BBB518eBe913b2896) |
| BNB Chain | 56 | [bscscan.com](https://bscscan.com/address/0xEF37b4902AD3eDc923112BD47C0D776bd2A419B3) | [bscscan.com](https://bscscan.com/address/0xC90079E3C00671B13a8f85d2FC2c9E9A0F3305D9) | [bscscan.com](https://bscscan.com/address/0xFd5602187ce9Cd6c53C8469BBB518eBe913b2896) |
| Base | 8453 | [basescan.org](https://basescan.org/address/0xEF37b4902AD3eDc923112BD47C0D776bd2A419B3) | [basescan.org](https://basescan.org/address/0xC90079E3C00671B13a8f85d2FC2c9E9A0F3305D9) | [basescan.org](https://basescan.org/address/0xFd5602187ce9Cd6c53C8469BBB518eBe913b2896) |
| Arbitrum One | 42161 | [arbiscan.io](https://arbiscan.io/address/0xEF37b4902AD3eDc923112BD47C0D776bd2A419B3) | [arbiscan.io](https://arbiscan.io/address/0xC90079E3C00671B13a8f85d2FC2c9E9A0F3305D9) | [arbiscan.io](https://arbiscan.io/address/0xFd5602187ce9Cd6c53C8469BBB518eBe913b2896) |
| HyperEVM | 999 | [hyperevmscan.io](https://hyperevmscan.io/address/0xEF37b4902AD3eDc923112BD47C0D776bd2A419B3) | [hyperevmscan.io](https://hyperevmscan.io/address/0xC90079E3C00671B13a8f85d2FC2c9E9A0F3305D9) | [hyperevmscan.io](https://hyperevmscan.io/address/0xFd5602187ce9Cd6c53C8469BBB518eBe913b2896) |
| Robinhood Chain | 4663 | [robinhoodchain.blockscout.com](https://robinhoodchain.blockscout.com/address/0xEF37b4902AD3eDc923112BD47C0D776bd2A419B3) | [robinhoodchain.blockscout.com](https://robinhoodchain.blockscout.com/address/0xC90079E3C00671B13a8f85d2FC2c9E9A0F3305D9) | [robinhoodchain.blockscout.com](https://robinhoodchain.blockscout.com/address/0xFd5602187ce9Cd6c53C8469BBB518eBe913b2896) |
| Elysium | 99901 | [elysium.kinetiq.xyz](https://elysium.kinetiq.xyz/address/0xEF37b4902AD3eDc923112BD47C0D776bd2A419B3) | [elysium.kinetiq.xyz](https://elysium.kinetiq.xyz/address/0xC90079E3C00671B13a8f85d2FC2c9E9A0F3305D9) | [elysium.kinetiq.xyz](https://elysium.kinetiq.xyz/address/0xFd5602187ce9Cd6c53C8469BBB518eBe913b2896) |

Source is verified on Sourcify and on every chain's block explorer.

## Security

The contracts have been through an internal review and a broad set of automated checks. **They have not been audited by a third party.** Every result below can be reproduced from this repository; details and the full SWC registry walk-through are in [SECURITY_REVIEW.md](SECURITY_REVIEW.md).

| Check | Tool | Result |
| --- | --- | --- |
| Unit, fuzz and invariant tests | Foundry | 179 tests passing; fuzz tests at 10,000 runs each (100,000 in the `deep` profile); invariants at 512 runs x 64 calls (2,000 x 128 in `deep`) |
| Test coverage | `forge coverage` | 100% of lines, statements, branches and functions in `src/` |
| Property-based fuzzing | Echidna 2.4.0 | 15 properties held over 500,000 random calls (harness: [`test/echidna/`](test/echidna)) |
| Static analysis | Slither 0.11.6 | 0 high; every medium, low and informational result reviewed: by design or false positive |
| Symbolic execution | Mythril | 0 issues on all three deployed contracts |
| SWC registry | Manual review | SWC-100 to SWC-136 checked one by one |
| Gas griefing and hostile recipients | Foundry tests | gas-burning and coin-rejecting wallets, 100 KB return-data bombs, re-entering recipients and tokens, USDT-style, false-returning and tax tokens |
| Oracle safety | Foundry tests | stale, zero, negative and future prices; L2 sequencer down or just restarted; misconfigured feeds |
| Reproducible build | [`script/verify-bytecode.sh`](script/verify-bytecode.sh) | 21 of 21 deployments (3 contracts x 7 chains) match this source byte for byte |

### Security properties

- **Non-custodial, holds nothing.** Tokens go sender to recipient in the same call; fees go straight to the treasury in the same call. Neither contract ever keeps tokens or coins (invariant-tested at random prices and treasury changes).
- **All-or-nothing.** Any failed transfer reverts the whole call: rejecting contract wallets, gas-burning recipients, tokens that return `false`, insufficient allowance or balance.
- **No surprise fees.** The user signs a maximum (`msg.value`). The contract charges the live fee, never more than that maximum, and refunds the rest in the same transaction. A failed refund reverts everything.
- **Safe oracle use.** Chainlink answers must be positive, timestamped, not from the future and newer than `maxPriceAge`; on L2s the sequencer must be up for over an hour. Any native charge above `maxNativeCharge` reverts. Free sends never read the oracle, so they work even if a feed is down.
- **Tiered, capped fee.** The fee depends on recipients per call (Bulmo: 1-5 free, 6-20 $10, 21-50 $19, 51+ $49, in USD, paid in native coin). Every tier fee is `<= maxFeeUsd` always, and both caps only ever decrease (invariant-tested). Every list size always has a price (the last tier covers 500).
- **Reentrancy-safe.** `nonReentrant` on every state-changing entry point; tested with a re-entering recipient and a re-entering token.
- **Non-standard tokens.** `SafeERC20` handles USDT-style tokens with no return value; tax tokens work (recipients get less, nothing gets stuck).
- **Input checks.** Empty lists, length mismatch, more than 500 recipients, zero address, zero amount and overflow all revert with clear custom errors (with the line index).
- **No accidental deposits.** No `receive()`/`fallback()`: plain transfers to the contract revert.
- **Small owner surface.** No pause, no upgrade, no proxy, no access to user funds. Ownership is two-step (`Ownable2Step`); `renounceOwnership` is disabled so prices and the treasury can always be managed.
- **Treasury safety.** A treasury that rejects coins makes paid sends revert (nothing is kept or lost) until the owner sets a working one; free sends keep working.

### Verify the deployed code yourself

The compiler settings are deterministic (`bytecode_hash = "none"`, no CBOR metadata, `evm_version = "paris"`), so anyone can rebuild the exact deployed bytecode:

```bash
git clone --recurse-submodules https://github.com/BulmoLabs/bulmo-multisend-contracts
cd bulmo-multisend-contracts
script/verify-bytecode.sh        # builds, then compares with the live code on all 7 chains
```

It reads public chain data only and needs [Foundry](https://getfoundry.sh) and `jq`.

### Reporting a vulnerability

Please email **contact@bulmo.xyz** and do not open a public issue. See [SECURITY.md](SECURITY.md).

## Integrate

Send native coin from your own code (TypeScript, [viem](https://viem.sh)). Get the ABI with `make abi`.

```ts
import { bulmoMultisendAbi } from "./abi/bulmo-multisend";

const MULTISEND = "0xEF37b4902AD3eDc923112BD47C0D776bd2A419B3";
const recipients = ["0x...", "0x..."] as const;
const amounts = [10n ** 16n, 2n * 10n ** 16n]; // 0.01 and 0.02 of the native coin
const total = amounts.reduce((a, b) => a + b, 0n);

// Live fee in wei for this many recipients (0 for 1 to 5).
const [feeNative] = await publicClient.readContract({
  address: MULTISEND, abi: bulmoMultisendAbi, functionName: "quote", args: [BigInt(recipients.length)],
});

// Pay up to the fee plus 2%: the contract charges the live fee and refunds the rest in the same transaction.
await walletClient.writeContract({
  address: MULTISEND, abi: bulmoMultisendAbi, functionName: "sendNative",
  args: [recipients, amounts], value: total + (feeNative * 102n) / 100n,
});
```

For ERC-20 tokens, approve the contract for the total, then call `sendToken(token, recipients, amounts)` with the fee as `value`. The contract only ever pulls tokens from the caller (`transferFrom(msg.sender, ...)`), so an approval can only be used by you.

## Contract reference

| File | Purpose |
| --- | --- |
| [`MultisendCore.sol`](src/MultisendCore.sol) | Shared sending logic: validation, native and token payouts, refunds. |
| [`UsdPricing.sol`](src/UsdPricing.sol) | Converts USD prices to the native coin with Chainlink (staleness and L2 sequencer checks), or a manual price on chains without an oracle. Hard native cap. |
| [`BulmoMultisend.sol`](src/BulmoMultisend.sol) | Pay-per-send multisend with tiered USD fees. |
| [`BulmoMultisendFactory.sol`](src/BulmoMultisendFactory.sol) | Sells Personal Multisends; each is an EIP-1167 clone at a deterministic address. |
| [`BulmoPersonalMultisend.sol`](src/BulmoPersonalMultisend.sol) | A customer-owned multisend: unlimited sends, no fee, owner plus up to 5 team wallets, no Bulmo powers. |

### Pay-per-send: `BulmoMultisend`

| Function | Who | What |
| --- | --- | --- |
| `sendNative(recipients, amounts)` | anyone | Sends native coin. `msg.value` must cover `sum(amounts) + feeFor(count)`; the fee goes to `treasury` and the excess is refunded, in the same call. |
| `sendToken(token, recipients, amounts)` | anyone | Sends an ERC-20 straight from the sender (`transferFrom`). `msg.value` must cover `feeFor(count)`; fee to `treasury`, excess refunded. Needs an approval of the total. |
| `quote(count)` | view | `(feeNative, feeUsd, price, updatedAt)` for a list size: what the dapp shows before signing. Zeros for free sends. |
| `feeFor(count)` / `feeUsdFor(count)` / `tiers()` | view | Live fee in wei, fee in USD (8 decimals), the USD tier table. |
| `maxFeeUsd()` / `maxNativeCharge()` / `nativeUsdPrice()` | view | Dollar cap, native-coin cap (wei), current price and its timestamp. |
| `setTiers(maxRecipients[], feesUsd[])` | owner | Replaces the tier table (1 to 5 tiers, ascending, last covers 500). Every fee <= `maxFeeUsd`. |
| `lowerMaxFeeUsd(newMax)` | owner | Lowers the dollar cap. It can never be raised again. Clamps any tier above it. |
| `setPriceSource(feed, sequencer, maxAge)` | owner | Chainlink native/USD feed, optional L2 sequencer feed, max answer age. `(0, 0, 0)` = manual mode. |
| `setManualPrice(price)` | owner | Native/USD price (8 decimals) for chains without Chainlink (Elysium). |
| `lowerMaxNativeCharge(newCap)` | owner | Lowers the hard cap on any single charge in wei. Can never be raised. |
| `setTreasury(addr)` / `treasury()` | owner / view | Where fees go, in the same transaction they are paid. Starts as the owner. |
| `sweep(to)` | owner | Recovers coins forced into the contract (fees never collect there). |
| `rescueTokens(token, to)` | owner | Returns tokens someone sent to the contract directly by mistake. |

### Personal Multisend: `BulmoMultisendFactory` + `BulmoPersonalMultisend`

| Function | Who | What |
| --- | --- | --- |
| `createPersonalMultisend(salt)` | anyone | Pays at least `currentPrice()` (sent to `treasury` in the same call, excess refunded), creates a clone owned by the caller. Same salt on every chain = same address. |
| `quotePrice()` / `currentPrice()` | view | `(priceNative, priceUsd, price, updatedAt)` / live price in wei. |
| `predictAddress(buyer, salt)` / `createdBy(buyer)` / `isPersonalMultisend(addr)` | view | Look up and verify Personal Multisends. |
| `setPriceUsd` / `lowerMaxPriceUsd` / `setPriceSource` / `setManualPrice` / `lowerMaxNativeCharge` / `setTreasury` / `sweep` | factory owner | Same rules as the main contract. |
| Personal: `sendNative` / `sendToken` | owner + operators | No fee. Native: `msg.value == total`. Token: no value. |
| Personal: `setOperator(addr, allowed)` | owner | Up to 5 team wallets; they send from their own wallets only. |
| Personal: `transferOwnership` / `acceptOwnership` / `rescue(token, to)` | owner | Two-step ownership; recover stray tokens or coins. |

## Build and test

Requires [Foundry](https://getfoundry.sh).

```bash
git clone --recurse-submodules https://github.com/BulmoLabs/bulmo-multisend-contracts
cd bulmo-multisend-contracts
make build        # compile and show contract sizes
make test         # 179 tests: unit, fuzz and invariant
make test-deep    # 100,000 fuzz runs and 2,000 invariant runs
make coverage     # coverage summary
make snapshot     # gas reference for 250 recipients
make abi          # export the ABIs to abi/bulmo-multisend.ts
echidna . --contract BulmoEchidna --config echidna.yaml   # property fuzzing (Echidna)
medusa fuzz                                               # property fuzzing (Medusa)
```

Dependencies are pinned git submodules: OpenZeppelin Contracts v5.1.0 and forge-std.

## Gas reference

| Operation | Gas |
| --- | --- |
| Native coin to 250 new wallets | ~9.61M |
| ERC-20 to 250 new wallets | ~7.63M |
| ERC-20 to 250 new wallets through a Personal Multisend | ~7.84M |
| Buy a Personal Multisend (clone and price read) | ~0.23M |

The Bulmo app splits long lists into batches that fit each chain's block gas limit (40 recipients per transaction on HyperEVM, whose small blocks hold 3M gas).

## FAQ

**Is Bulmo Multisend audited?**
Not by a third party yet. The code has an internal review, 100% test coverage, property fuzzing with Echidna, static analysis with Slither and symbolic execution with Mythril, and the deployed bytecode is reproducible from this repository. See [Security](#security).

**Can Bulmo take my tokens or coins?**
No. The contracts only move tokens from the caller to the recipients the caller lists, in the same transaction. There is no upgrade, no pause and no function that can spend a user's approval. The owner can only set fees within the $100 cap, pick the price source and treasury, and recover coins or tokens sent to the contract by mistake.

**What happens if one recipient cannot receive?**
The whole transaction reverts and nobody is paid, so a list is never half-sent. Fix or remove that address and send again.

**Can fees go up without warning?**
Every fee is capped at $100 per transaction, and that cap can only be lowered. You also sign a maximum amount: the contract never charges more than you signed, and if the live fee rose above it the transaction fails instead. Every pricing change emits an on-chain event.

**Which tokens work?**
Any ERC-20, including tokens that return no value (like USDT) and fee-on-transfer tokens (recipients receive the amount minus the token's own tax).

**Why is the address the same on every chain?**
The contracts were deployed with CREATE2 using identical bytecode, salt and constructor arguments on every chain.

## License

[MIT](LICENSE). Copyright (c) 2026 Bulmo Labs.
