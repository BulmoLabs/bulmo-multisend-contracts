# Bulmo Multisend: security testing report

**Date:** 2026-11-24 · **Prepared by:** the Bulmo team · **Type:** internal testing, **not a third-party audit**

This report collects every automated security check run on the Bulmo Multisend contracts, with the exact tool versions, settings and results. Every result can be reproduced from this repository with the commands in [Reproduce every result](#reproduce-every-result). The manual review, the SWC registry walk-through and the design rationale are in [SECURITY_REVIEW.md](../SECURITY_REVIEW.md). A machine-readable version of this page is in [summary.json](summary.json).

## Summary

| Check | Tool | Setting | Result |
| --- | --- | --- | --- |
| Deployed code matches this source | `script/verify-bytecode.sh` | 3 contracts on 7 chains | **21 of 21 match** byte for byte |
| Unit, fuzz and invariant tests | Foundry 1.5.1 | default profile | **179 passing**, 0 failing |
| Deep fuzz and invariant run | Foundry 1.5.1 | 100,000 runs per fuzz test; 2,000 runs x 128 calls per invariant | **all passing** |
| Test coverage | `forge coverage` | `src/` only | **100%** lines (293/293), statements (349/349), branches (71/71), functions (57/57) |
| Property fuzzing | Medusa 1.5.1 | 10 properties, 14 fuzzed functions | **10,055,497 calls, 0 failures** |
| Property fuzzing | Echidna 2.4.0 | same harness | **500,000 calls, 0 failures** |
| Formal verification (symbolic proofs) | Halmos 0.3.3 | 8 proofs over all inputs | **7 proven**, 1 inconclusive (solver timeout; covered by fuzzing) |
| Static analysis | Slither 0.11.6 | all detectors | **0 high**; 6 medium, 9 low, 4 informational, every one reviewed: by design or false positive |
| Symbolic execution | Mythril 0.24.8 | 3 deployed contracts | **0 issues** |
| SWC registry | manual | SWC-100 to SWC-136 | **all checked**, see [SECURITY_REVIEW.md](../SECURITY_REVIEW.md#swc-registry-swc-100-to-swc-136) |

No test, fuzzer, prover or analyzer found a way to take user funds, charge more than the user signed, leave funds in a contract, or use an owner function without being the owner.

## Scope

| File | SHA-256 |
| --- | --- |
| [`src/MultisendCore.sol`](../src/MultisendCore.sol) | `f6d82cd2152220ef0803e559d646087d990abca3f23e36cd26c40f71af41b14c` |
| [`src/UsdPricing.sol`](../src/UsdPricing.sol) | `7965493c47a5a7b672819785e99251b1032d13dbc5a096bfa94979e57024358e` |
| [`src/BulmoMultisend.sol`](../src/BulmoMultisend.sol) | `0a8f14ce45d1279455b970253ee6a35d9013b8db7543f0ff44cdef3a1a749216` |
| [`src/BulmoMultisendFactory.sol`](../src/BulmoMultisendFactory.sol) | `4fb169efff102e0aed22a8369e9b4b54ea9774d59084f931f5248b4f5bf8cf91` |
| [`src/BulmoPersonalMultisend.sol`](../src/BulmoPersonalMultisend.sol) | `fd9f467fea2f9cb5053b07c27ffa8a3c5c22a551e7540506718e7b0d989b4910` |

Solidity 0.8.28, `evm_version = paris`, optimizer 10,000 runs, `bytecode_hash = none`, no CBOR metadata. Dependencies: OpenZeppelin Contracts v5.1.0 (pinned submodule, identical to the upstream tag) and forge-std (test only).

Deployed at the same addresses on Ethereum, BNB Chain, Base, Arbitrum One, HyperEVM, Robinhood Chain and Elysium:

| Contract | Address |
| --- | --- |
| `BulmoMultisend` | `0xEF37b4902AD3eDc923112BD47C0D776bd2A419B3` |
| `BulmoMultisendFactory` | `0xC90079E3C00671B13a8f85d2FC2c9E9A0F3305D9` |
| `BulmoPersonalMultisend` (clone implementation) | `0xFd5602187ce9Cd6c53C8469BBB518eBe913b2896` |

## 1. Reproducible bytecode

`script/verify-bytecode.sh` builds this repository and compares the result with the code stored on-chain at each address. The factory's one immutable value (the clone implementation address) is filled with `0xFd5602187ce9Cd6c53C8469BBB518eBe913b2896` before comparing, so the check also proves which implementation every Personal Multisend clone runs.

| Chain | BulmoMultisend | BulmoMultisendFactory | BulmoPersonalMultisend |
| --- | --- | --- | --- |
| Ethereum (1) | match | match | match |
| BNB Chain (56) | match | match | match |
| Base (8453) | match | match | match |
| Arbitrum One (42161) | match | match | match |
| HyperEVM (999) | match | match | match |
| Robinhood Chain (4663) | match | match | match |
| Elysium (99901) | match | match | match |

Because the contracts have no proxy and no upgrade function, this is the code that runs, permanently.

## 2. Tests and coverage

179 Foundry tests in [`test/`](../test): unit tests, fuzz tests (10,000 runs each by default) and stateful invariant tests (512 runs x 64 calls by default) for both products. The `deep` profile raises this to 100,000 fuzz runs and 2,000 x 128 invariant calls, and passes too.

| File | Lines | Statements | Branches | Functions |
| --- | --- | --- | --- | --- |
| `BulmoMultisend.sol` | 100% (100/100) | 100% (119/119) | 100% (17/17) | 100% (18/18) |
| `BulmoMultisendFactory.sol` | 100% (67/67) | 100% (70/70) | 100% (12/12) | 100% (17/17) |
| `BulmoPersonalMultisend.sol` | 100% (48/48) | 100% (51/51) | 100% (15/15) | 100% (10/10) |
| `MultisendCore.sol` | 100% (28/28) | 100% (40/40) | 100% (8/8) | 100% (6/6) |
| `UsdPricing.sol` | 100% (50/50) | 100% (69/69) | 100% (19/19) | 100% (6/6) |
| **Total** | **100% (293/293)** | **100% (349/349)** | **100% (71/71)** | **100% (57/57)** |

### Gas griefing and hostile counterparties

| Attack or edge case | Expected behaviour | Test |
| --- | --- | --- |
| Recipient burns all gas it receives | whole send reverts; nobody is partly paid | `test_sendNative_gasGuzzlerCannotPartiallyPay` |
| Recipient returns 100 KB of data (return-data bomb) | ignored; the sender pays no memory cost for it | `test_sendNative_largeReturnDataIsIgnored` |
| Recipient contract rejects coins | whole send reverts, sender keeps everything | `test_sendNative_allOrNothingWhenARecipientRejects` |
| Recipient re-enters the contract | blocked by `nonReentrant` | `test_sendNative_blocksReentrancy` |
| Token re-enters during `transferFrom` | blocked | `test_sendToken_blocksReentrantToken`, `test_personal_blocksReentrantToken` |
| Refund recipient re-enters | blocked; whole call reverts | `test_payUpTo_refundCannotReenter` |
| Refund fails | whole call reverts; nothing kept or lost | `test_payUpTo_refundFailureRevertsEverything`, `test_buy_refundFailureRevertsWholePurchase` |
| Treasury rejects coins or re-enters | paid sends revert, free sends keep working | `test_treasury_rejectingTreasuryRevertsPaidSendEntirely`, `test_treasury_reentrantTreasuryCannotReenter` |
| USDT-style token (no return value) | works | `test_sendToken_usdtStyleNoReturnValue`, `test_personal_usdtStyleToken` |
| Token returns `false` | reverts | `test_sendToken_revertsWhenTokenReturnsFalse` |
| Fee-on-transfer (tax) token | recipients get less; nothing stuck | `test_sendToken_taxTokenDeliversLessButNothingStuck` |
| 500 recipients, 501 recipients | 500 works, 501 reverts | limits tests in `test/BulmoMultisend.t.sol` |

### Oracle failure cases

| Case | Expected behaviour | Test |
| --- | --- | --- |
| Stale price | paid sends revert | `test_oracle_staleAnswerReverts`, `test_buy_revertsOnStaleOrBrokenFeed` |
| Zero, negative or future-dated price | paid sends revert | `test_oracle_badAnswersRevert` |
| L2 sequencer down or restarted less than 1 hour ago | paid sends revert | `test_oracle_sequencerDownAndGracePeriod` |
| Feed reports an absurdly low price | the native cap blocks the charge | `test_nativeCap_blocksAbsurdChargeFromBrokenFeed`, `test_buy_nativeCapBlocksAbsurdCharge` |
| Feed broken | free sends still work | `test_oracle_paidSendRevertsButFreeSendWorksWhenFeedBroken`, `test_quote_freeTierIsAllZerosEvenWithBrokenFeed` |
| Feed with 0 to 18 decimals | scaled exactly | `test_oracle_feedDecimalsScaled`, fuzz `feedDecimals_*` |
| Rounding | always up, by less than 1 wei | `test_oracle_roundsUpNeverUndercharges`, fuzz `usdToNative_ceilWithinOneWei` |

## 3. Property fuzzing: Echidna and Medusa

The harness [`test/echidna/BulmoEchidna.sol`](../test/echidna/BulmoEchidna.sol) owns a full deployment (multisend, factory, a Personal Multisend, a Chainlink-style feed and a token). The fuzzer calls 14 functions in random order with random arguments: user sends (funded and underfunded), purchases, coin price moves, fee and cap changes by the owner, and attacks by an address with no rights. Time and blocks move forward between calls. After each call it asserts:

| ID | Property |
| --- | --- |
| P1 | A correctly funded send never fails, pays every recipient exactly and refunds the sender exactly. |
| P2 | An underfunded send always reverts and moves nothing. |
| P3 | The treasury receives exactly the fees and purchases charged, in the same transaction. |
| P4 | The contracts never keep native coin or tokens. |
| P5 | `maxFeeUsd`, `maxNativeCharge` and `maxPriceUsd` only go down; raising them always reverts. |
| P6 | No tier fee is above `maxFeeUsd`; the factory price is never above `maxPriceUsd`. |
| P7 | Nobody but the owner can change settings, move funds or take ownership (16 privileged calls tried). |
| P8 | Only the owner or an operator can send through a Personal Multisend, and it charges no fee. |
| P9 | A Personal Multisend purchase charges exactly the quoted price and gives the clone to the buyer. |
| P10 | Ownership never changes without the two-step transfer. |

| Fuzzer | Calls | Sequence length | Result |
| --- | --- | --- | --- |
| Medusa 1.5.1 | 10,055,497 | 100 | 14 of 14 functions passing, 0 failures |
| Echidna 2.4.0 | 500,000 | 100 | all passing, 0 failures |

A Foundry test ([`test/echidna/BulmoEchidna.t.sol`](../test/echidna/BulmoEchidna.t.sol)) calls every harness function once, so a broken harness also fails `forge test`.

## 4. Formal verification: Halmos

[`test/halmos/BulmoSymbolic.t.sol`](../test/halmos/BulmoSymbolic.t.sol) holds symbolic proofs. Halmos treats every argument as an unknown and checks the assertions for **all possible values**, not random samples. Loops are unrolled up to 8 iterations.

| ID | Property | Result |
| --- | --- | --- |
| S1 | USD to coin conversion rounds up by less than 1 wei and never exceeds the native cap | **Inconclusive:** the solver did not finish within 40 minutes (512-bit `mulDiv` arithmetic). Covered by fuzz test `usdToNative_ceilWithinOneWei` (10,000 runs; 100,000 in `deep`), unit tests and both property fuzzers. |
| S2 | Whatever tier table the owner sets, no fee is ever above `maxFeeUsd` | **Proven** (11 paths) |
| S3 | `maxFeeUsd` can only go down, and tiers above a new cap are cut to it | **Proven** (17 paths) |
| S4 | `maxNativeCharge` can only go down | **Proven** (2 paths) |
| S5 | A native send to 2 recipients pays both exactly, the treasury exactly the fee, refunds the rest and leaves nothing in the contract, for any amounts, coin price ($0.01 to $10M) and payment | **Proven** (13 paths, Bitwuzla solver) |
| S6 | Nobody but the owner can call any of 8 privileged functions, and owner and treasury stay unchanged | **Proven** (10 paths) |
| S7 | Only the owner or an operator can send through a Personal Multisend | **Proven** (2 paths) |
| S8 | A Personal Multisend purchase charges exactly the price and refunds the rest | **Proven** (8 paths) |

## 5. Static analysis: Slither

Slither 0.11.6, all detectors, on `src/`. 19 results: 0 high, 6 medium, 9 low, 4 informational. Each was reviewed:

| Impact | Detector | Where | Verdict |
| --- | --- | --- | --- |
| Medium | incorrect-equality | `sweep`: `amount == 0` (multisend and factory) | By design: only decides whether there is anything to recover. |
| Medium | uninitialized-local | `_setTiers`: `previous` | By design: starts at 0 so the first tier bound must be above 0. |
| Medium | uninitialized-local | `_setPriceSource`: `dec` | By design: stays 0 in manual-price mode, where no feed exists. |
| Medium | unused-return | `nativeUsdPrice`: feed and sequencer `latestRoundData` | By design: `roundId` and `answeredInRound` are deprecated by Chainlink; freshness is checked on `updatedAt`. |
| Low | missing-zero-check | constructors: `treasury = initialOwner` | False positive: OpenZeppelin `Ownable` rejects a zero owner in the same constructor. |
| Low | missing-zero-check | `BulmoPersonalMultisend.transferOwnership` | By design: passing zero cancels a pending transfer (tested). |
| Low | timestamp (6) | staleness, sequencer and payment comparisons | By design: the oracle checks use time on purpose (minutes-scale, so validator drift is irrelevant); the other flagged lines compare amounts, not time. |
| Informational | assembly (3) | `_payNative`, `_sendValue` | By design: a raw `call` that does not copy return data, which is what defeats return-data bombs. |
| Informational | low-level-calls | `BulmoPersonalMultisend.rescue` | By design: owner-only, sends to an address the owner chooses. |

## 6. Symbolic execution: Mythril

Mythril 0.24.8 on each deployed contract with the production compiler settings: `BulmoMultisend`, `BulmoMultisendFactory` and `BulmoPersonalMultisend` all reported **0 issues**.

## Limitations

- **No third-party audit.** This is the Bulmo team's own testing. Tools find classes of bugs; they do not prove the absence of every bug.
- **S1 is not formally proven.** The rounding property is backed by fuzzing and unit tests, not by a symbolic proof.
- **Halmos proofs are bounded.** Loops are unrolled up to 8 iterations, and some proofs fix the list size (for example S5 uses 2 recipients).
- **Owner powers exist.** The owner can change fee tiers (within the $100 cap that only goes down), set the price source and treasury, and recover coins or tokens sent to the contracts by mistake. The owner cannot touch user funds or approvals. Ownership is currently a single key; moving it to a Safe multisig on every chain is planned.
- **Elysium uses a manual price.** There is no Chainlink feed on Elysium yet, so paid sends there would rely on an owner-set price. Only free sends are open on Elysium today.

## Reproduce every result

```bash
git clone --recurse-submodules https://github.com/BulmoLabs/bulmo-multisend-contracts
cd bulmo-multisend-contracts

script/verify-bytecode.sh                                         # bytecode vs all 7 chains
forge test                                                        # 179 tests
FOUNDRY_PROFILE=deep forge test                                   # deep fuzz and invariants
forge coverage --report summary --no-match-coverage "(test|script)/"
medusa fuzz                                                       # property fuzzing (set fuzzing.testLimit for longer runs)
echidna . --contract BulmoEchidna --config echidna.yaml            # property fuzzing
halmos --match-contract BulmoSymbolic --loop 8 --solver bitwuzla  # symbolic proofs
slither .                                                         # static analysis
```

Mythril, per contract (Docker; mount solc 0.8.28 as `/usr/local/bin/solc`):

```bash
docker run --rm -v "$PWD":/src -w /src mythril/myth analyze src/BulmoMultisend.sol:BulmoMultisend \
  --solc-json mythril-solc.json --no-onchain-data
```

[`mythril-solc.json`](../mythril-solc.json) holds the remappings and the production compiler settings.

## Reporting a vulnerability

Email **contact@bulmo.xyz**. See [SECURITY.md](../SECURITY.md).
