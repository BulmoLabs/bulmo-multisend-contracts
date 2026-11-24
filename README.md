# Bulmo Multisend contracts

Smart contracts behind [Bulmo Multisend](https://bulmo.xyz): pay many wallets in one transaction, in a chain's native coin or any ERC-20 token. Built with Foundry, Solidity 0.8.28 and OpenZeppelin 5.1. Use it at [app.bulmo.xyz](https://app.bulmo.xyz). Security: [SECURITY_REVIEW.md](SECURITY_REVIEW.md).

| Contract | What |
| --- | --- |
| `MultisendCore.sol` | Shared sending logic (validation, native + token payouts, refunds). One implementation for both products. |
| `UsdPricing.sol` | USD prices converted to the native coin with Chainlink (staleness + L2 sequencer checks), or a manual price on chains without an oracle. Hard native cap. |
| `BulmoMultisend.sol` | Pay-per-send: tiered USD fee by recipients per call (1-5 free, 6-20 $10, 21-50 $19, 51+ $49), paid in native coin at the live price. |
| `BulmoMultisendFactory.sol` | Sells Personal Multisends ($49 once), each an EIP-1167 clone. Same USD pricing, caps and refunds. |
| `BulmoPersonalMultisend.sol` | A customer-owned Multisend: unlimited sends, no fee, owner + up to 5 team wallets, no Bulmo powers. |

```bash
make build        # compile + contract size
make test         # 179 tests: unit, fuzz (10k runs each), invariants (512 runs x 64 calls) for both products
make test-deep    # 100k fuzz runs + 2k invariant runs: run before every deploy
make coverage     # 100% lines, statements, branches and functions on every contract in src/
make snapshot     # gas reference for 250 recipients
make abi          # export the ABIs to abi/bulmo-multisend.ts (ABI_OUT=<dir> to change)
```

## Deployed (2026-11-22)

Same addresses on Ethereum, BNB Chain, Base, Arbitrum, HyperEVM, Robinhood Chain and Elysium:

| Contract | Address |
| --- | --- |
| `BulmoMultisend` | `0xEF37b4902AD3eDc923112BD47C0D776bd2A419B3` |
| `BulmoMultisendFactory` | `0xC90079E3C00671B13a8f85d2FC2c9E9A0F3305D9` |
| `BulmoPersonalMultisend` (clone implementation) | `0xFd5602187ce9Cd6c53C8469BBB518eBe913b2896` |

Price sources are set everywhere except Elysium. Source verified on Sourcify and on every chain's block explorer. The compiler settings below are deterministic, so building this repo reproduces the deployed bytecode exactly. Ownership is planned to move from the deployer key to a Safe multisig on every chain.

## Pay-per-send: `src/BulmoMultisend.sol`

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

## Personal Multisend: factory + clone

| Function | Who | What |
| --- | --- | --- |
| `createPersonalMultisend(salt)` | anyone | Pays at least `currentPrice()` (sent to `treasury` in the same call, excess refunded), creates a clone owned by the caller. Same salt on every chain = same address. |
| `quotePrice()` / `currentPrice()` | view | `(priceNative, priceUsd, price, updatedAt)` / live price in wei. |
| `predictAddress(buyer, salt)` / `createdBy(buyer)` / `isPersonalMultisend(addr)` | view | Look up and verify Personal Multisends. |
| `setPriceUsd` / `lowerMaxPriceUsd` / `setPriceSource` / `setManualPrice` / `lowerMaxNativeCharge` / `setTreasury` / `sweep` | factory owner | Same rules as the main contract. |
| Personal: `sendNative` / `sendToken` | owner + operators | No fee. Native: `msg.value == total`. Token: no value. |
| Personal: `setOperator(addr, allowed)` | owner | Up to 5 team wallets; they send from their own wallets only. |
| Personal: `transferOwnership` / `acceptOwnership` / `rescue(token, to)` | owner | Two-step ownership; recover stray tokens or coins. |

### Security properties (each covered by tests)

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

### Compiler settings

- `evm_version = paris`: no `PUSH0`, so the same bytecode runs on all supported chains.
- `bytecode_hash = none`, no CBOR metadata: deterministic bytecode, so CREATE2 gives **the same address on every chain**.

## Gas reference (fresh recipient wallets)

| Send | 250 recipients |
| --- | --- |
| Native coin | ~9.61M gas |
| ERC-20 | ~7.63M gas |
| Personal Multisend purchase (clone, with oracle read) | ~0.26M gas |

The Bulmo app splits long lists into batches that stay below each chain's block gas limit. HyperEVM's small blocks hold 3M gas, so batches there are 40 recipients.

## Deploying

The CREATE2 factory (`0x4e59b44847b379578588920cA78FbF26c0B4956C`) is live on all 7 chains (checked: Ethereum, BNB Chain, Base, Arbitrum, HyperEVM, Robinhood Chain, Elysium), so one address works everywhere **if every constructor argument and salt is identical on every chain**. Dollar prices are the same everywhere, so the real tier table ships at deploy. Each chain then gets its own price source.

1. `cp .env.example .env` and fill `OWNER` (a multisig) and RPC URLs. Defaults: $100 cap, tiers $0 / $10 / $19 / $49, factory $49 (cap $100), native cap 10 coins.
2. Import the deployer key once into Foundry's encrypted keystore (never a plain key in `.env`):
   `cast wallet import deployer --interactive`
3. Run `make test-deep`.
4. Testnet first, then each mainnet: `make deploy-dry CHAIN=base`, check the predicted address, then `make deploy CHAIN=base`.
   HyperEVM: the factory (3.34M gas) needs big blocks; small blocks hold 3M. Multisend uses 2.85M, but Foundry's padded gas limit exceeds 3M, so use big blocks for both. The deployer must be an active HyperCore account to switch.
   Ledger: add `HW=ledger FROM=0x<address>` to `deploy`, `deploy-factory` and `pricing`; `make ledger-list` shows the device's addresses.
5. Deploy the factory the same way: `make deploy-factory CHAIN=base`.
6. Verify on each explorer (Etherscan family via one `ETHERSCAN_API_KEY`; Robinhood Chain and Elysium use Blockscout-style explorers: `--verifier blockscout --verifier-url <explorer>/api`).
7. Connect the price source. Until this runs, paid sends revert with `PriceUnavailable` and free sends work.
   - Ethereum, BNB Chain, Base, Arbitrum, HyperEVM, Robinhood Chain (feeds built in, all checked live):
     `make pricing CHAIN=base MULTISEND=0x... FACTORY=0x...`
   - Robinhood Chain: add `SEQUENCER_FEED=0x...` once Chainlink lists its L2 uptime feed.
   - Elysium (no Chainlink): `MANUAL_PRICE=<HYPE price, 8 decimals>`.
   The script checks the feed's `description()`, decimals, freshness and sequencer on-chain before sending anything, then prints every tier's live fee and a suggested native cap (~$300 worth). Run `make pricing-dry ...` first.
   Safe owner: `make pricing-safe ...` prints the calls to submit in the Safe app.
8. Lower the native cap per chain with `NEW_MAX_NATIVE_CHARGE=<wei>` on the same command (it only goes down, so leave room for the coin falling).
   Fees go to the owner by default. To send them to a different wallet on a chain (for example that chain's treasury Safe), add `TREASURY=0x...`.

## Still open

- Independent third-party audit of `src/` (about 530 lines of production code). Internal review: [SECURITY_REVIEW.md](SECURITY_REVIEW.md).
- Owner = Safe multisig on every chain.
