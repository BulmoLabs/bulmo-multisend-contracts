# Security review: Bulmo Multisend contracts

Internal review by the Bulmo team. **This is not a third-party audit.** Every claim below points to a test or tool run you can reproduce from this repository.

**Scope:** `src/MultisendCore.sol`, `src/UsdPricing.sol`, `src/BulmoMultisend.sol`, `src/BulmoPersonalMultisend.sol`, `src/BulmoMultisendFactory.sol` (Solidity 0.8.28, OpenZeppelin 5.1.0, `evm_version = paris`).

**Method:** line-by-line manual review focused on fund accounting, access control, reentrancy, gas and griefing; full SWC registry walk-through (below); static analysis with Slither 0.11.6 (no high or medium findings; all results triaged below) and Mythril symbolic execution (0 issues on all three deployed contracts); property fuzzing with Echidna 2.4.0 (15 properties, 500,000 calls, all passing; harness in `test/echidna/`); 179 Foundry tests (unit, fuzz at 10k / 100k runs, invariants at 512 x 64 / 2,000 x 128 calls); 100% line, statement, branch and function coverage; end-to-end runs on a local chain with the real deploy and pricing scripts, a mock Chainlink feed, quoted sends with a 2% margin and refund checks to the wei.

## Findings

| # | Severity | Finding | Status |
| --- | --- | --- | --- |
| 1 | Low (hardening) | Native payouts used `call` with return-data copying: a recipient returning large data made the caller pay memory costs for it. No funds at risk (all-or-nothing), but it wasted gas and was an avoidable edge case. | **Fixed:** raw `call` with no return-data copy in `MultisendCore._payNative` (also saves ~10.7k gas per 250-recipient native send). Test: `test_sendNative_largeReturnDataIsIgnored`. |
| 2 | Info | Factory wrote state after calling the clone's `initialize` (Slither reentrancy-benign). Not exploitable: trusted code created in the same transaction, `nonReentrant`. | **Fixed:** effects moved before the call. |
| 3 | Info | Tier fees stored as `uint224`; truncation would be possible if the cap exceeded `type(uint224).max`. | **Fixed:** constructor rejects such a cap; casts documented. Test: `test_constructor_revertsIfCapTooLargeToStore`. |
| 4 | Info | `clamped` local relied on default initialisation. | **Fixed:** explicit `false`. |
| 5 | Info (by design) | Slither "dangerous strict equality" on `amount == 0` in `sweep`. | Accepted: only decides whether there is anything to withdraw; force-sent coins just add to it. |
| 6 | Info (by design) | Slither "missing zero check" on `BulmoPersonalMultisend.transferOwnership`. | Accepted: `address(0)` cancels a pending transfer (tested). |
| 7 | Low (design) | Fixed native-coin prices drift with the coin's USD price, so the real fee changes every day and needs constant manual repricing on 7 chains. | **Changed:** prices are in USD (8 decimals) and converted at send time with Chainlink (`UsdPricing`). See "Oracle pricing" below. |
| 8 | Medium (design, prevented) | An oracle can be stale, return 0 / negative, report from an L2 whose sequencer is down, or be misconfigured, which could make a fee wrong. | **Mitigated:** answer > 0, timestamp set and not in the future, age <= `maxPriceAge`, L2 sequencer up for > 1 hour, feed decimals <= 18, and every native charge capped by `maxNativeCharge` (only decreases). Free sends never read the oracle. |
| 9 | Low (design) | Exact `msg.value` no longer works with a live price (the fee moves between quote and send). | **Changed:** "pay up to": `msg.value` must cover the live fee; the excess is refunded in the same call. A refund that fails reverts the whole call (`RefundFailed`), so nothing is ever kept or lost. |
| 10 | Info (by design) | Slither "unused return" on `latestRoundData` (`roundId`, `answeredInRound`). | Accepted: `answeredInRound` is deprecated by Chainlink; staleness is checked on `updatedAt`. |
| 11 | Info (by design) | Slither "timestamp" on the staleness and sequencer checks, and "uninitialized local" on `dec` in manual mode. | Accepted: timestamps are the point of those checks (minutes-scale, so validator drift is irrelevant); `dec` is 0 on purpose when there is no feed. |
| 12 | Info (residual) | In manual mode (Elysium) the price is whatever the owner last set; there is no staleness check. | Accepted, bounded: `maxNativeCharge` caps every charge; the owner must update it when HYPE moves (`ManualPriceUpdated` events are public). Switch to a Chainlink feed when one exists. |

| 13 | Design change | Fees were held in the contract until the owner withdrew them. | **Changed:** every fee and purchase payment is forwarded to `treasury` in the same transaction (raw call, all gas, no return-data copy), before the refund, under `nonReentrant`. Contracts never hold coins. `withdrawFees` replaced by `sweep` (only for coins forced in). |
| 14 | Low (accepted) | A treasury that rejects coins, runs out of gas or re-enters makes paid sends revert (`FeeTransferFailed` / `PaymentTransferFailed`). | Accepted: owner-controlled, fails safe (nothing kept or lost), fixed with `setTreasury`; free sends unaffected. `setTreasury` rejects zero and the contract itself. Tests: `treasury_*`, `rejectingTreasury*`. |

No critical, high or medium issues found.

## SWC registry (SWC-100 to SWC-136)

| SWC | Weakness | Result |
| --- | --- | --- |
| 100 | Function default visibility | Pass: every function has explicit visibility |
| 101 | Integer overflow / underflow | Pass: Solidity 0.8 checked math; the only `unchecked` is a purchase counter |
| 102 | Outdated compiler | Pass: 0.8.28 |
| 103 | Floating pragma | Pass: `pragma solidity 0.8.28` pinned in every file (OZ `^0.8.20` compiled with 0.8.28) |
| 104 | Unchecked call return value | Pass: native `call` results checked (payouts, refunds, withdrawals); tokens via `SafeERC20`; oracle answers validated |
| 105 | Unprotected ether withdrawal | Pass: no fee balance exists to withdraw (forwarded to the treasury per call); `sweep` / `rescue` are owner-only |
| 106 | Unprotected SELFDESTRUCT | Pass: not used |
| 107 | Reentrancy | Pass: `nonReentrant` on every state-changing entry point; effects before interactions; tested with re-entering recipient and token |
| 108 | State variable default visibility | Pass: explicit |
| 109 | Uninitialized storage pointer | N/A (0.8) |
| 110 | Assert violation | Pass: no `assert` |
| 111 | Deprecated functions | Pass: none (`.transfer`/`.send` not used) |
| 112 | Delegatecall to untrusted callee | Pass: clones delegate only to the factory's immutable, locked implementation |
| 113 | DoS with failed call | By design: a failing recipient reverts only that sender's own send (all-or-nothing, documented). Fees are pushed to the owner-set treasury; a broken treasury blocks only paid sends until the owner replaces it (free sends keep working) |
| 114 | Transaction order dependence / front-running | Pass: the user signs a maximum (`msg.value`); a fee/tier/price change between review and send can only charge up to that maximum (else it reverts), and any unused amount is refunded in the same call; dollar fees are capped and caps only fall; clone salt includes the buyer, so addresses can't be squatted; approvals are exact amounts the contract only uses on the sender's own call |
| 115 | Authorization through tx.origin | Pass: not used |
| 116 | Block values as time proxy | Pass: `block.timestamp` is used only for oracle staleness and the sequencer grace period (minutes to hours), where a few seconds of drift does not matter |
| 117 | Signature malleability | N/A: no signatures |
| 118 | Incorrect constructor name | N/A |
| 119 | Shadowing state variables | Pass: none (Slither shadowing detectors clean) |
| 120 | Weak randomness | N/A |
| 121 | Signature replay | N/A |
| 122 | Improper signature verification | N/A |
| 123 | Requirement violation | Pass: inputs validated with custom errors |
| 124 | Write to arbitrary storage | Pass: none |
| 125 | Incorrect inheritance order | Pass: no conflicting functions across `MultisendCore`, `Ownable2Step`, `ReentrancyGuard`, `Initializable` |
| 126 | Insufficient gas griefing | Pass: no relayed calls; all gas forwarded to recipients |
| 127 | Arbitrary jump with function type variable | Pass: none |
| 128 | DoS with block gas limit | Pass: recipients capped at 500, tiers at 5, operators at 5; `createdBy` list is read-only (view) |
| 129 | Typographical error | Pass |
| 130 | Right-to-left override character | Pass: source is plain ASCII (checked) |
| 131 | Unused variables | Pass |
| 132 | Unexpected ether balance | Pass: no logic depends on an exact balance; force-sent coins only add to withdrawable fees |
| 133 | Hash collision with `abi.encodePacked` | Pass: salts use `abi.encode` |
| 134 | Hardcoded gas amount | Pass: none (`gas()` forwarded) |
| 135 | Code with no effects | Pass |
| 136 | Unencrypted private data on-chain | N/A |

## Fee and price change protections

| Protection | Main contract | Factory |
| --- | --- | --- |
| Only the owner can change pricing | `setTiers`, `lowerMaxFeeUsd`, `setPriceSource`, `setManualPrice`, `lowerMaxNativeCharge` | `setPriceUsd`, `lowerMaxPriceUsd`, `setPriceSource`, `setManualPrice`, `lowerMaxNativeCharge` |
| Dollar price never above a hard cap | every tier fee <= `maxFeeUsd` | `priceUsd` <= `maxPriceUsd` |
| Native charge never above a hard cap | `usdToNative` reverts above `maxNativeCharge` | same |
| Caps can only go down, never up | `lowerMaxFeeUsd` (clamps tiers), `lowerMaxNativeCharge` | `lowerMaxPriceUsd` (clamps price), `lowerMaxNativeCharge` |
| User never pays more than they signed | `msg.value` is the maximum; live fee charged, rest refunded | same |
| User never pays more than the live price | contract charges `feeFor(n)` at execution, not the quoted amount | `currentPrice()` |
| Every change is public on-chain | `TiersUpdated`, `MaxFeeUsdLowered`, `PriceSourceUpdated`, `ManualPriceUpdated`, `MaxNativeChargeLowered` | `PriceUsdUpdated`, `MaxPriceUsdLowered`, plus the same three pricing events |
| Table always valid | 1-5 tiers, strictly ascending, last covers 500 | n/a |
| Personal Multisends unaffected by any pricing change | n/a | no fee exists in the clone |

Tests: `refundsOverpayment`, `revertsIfFeeRaisedAfterReview`, `feeLoweredAfterReviewChargesLess`, `tierBoundaryChangedAfterReview_reverts`, `payUpTo_*`, `buy_refundsOverpayment`, `buy_revertsIfPriceRaisedAboveWhatWasSent`, `buy_coinPriceRiseWithinBufferIsRefunded`, `feeChangesAreAlwaysPublic`, `priceChangesAreAlwaysPublic`, `lowerMaxFeeUsd_*`, `lowerMaxPriceUsd_*`, `nativeCap_*`, fuzz `setTiers_succeedsIffAllWithinCap`, `lowerMaxFeeUsd_neverIncreasesAndClamps`, `lowerMaxNativeCharge_neverIncreases`, `nativeCap_isHardLimit`, invariants `feeNeverAboveCap`, `capsOnlyDecrease`, `refundsExactAndChargesCapped`, `priceNeverAboveCap`, `refundsExact`.

## Oracle pricing (`UsdPricing`)

Prices are stored in USD with 8 decimals ($49 = `49e8`), identical on every chain. At send time the contract reads the chain's native/USD price and converts: `native = ceil(usd * 1e18 / price)` (`Math.mulDiv`, rounded up, so it never undercharges and overcharges by under 1 wei).

| Check | Behaviour | Tested by |
| --- | --- | --- |
| Answer <= 0, `updatedAt` = 0 or in the future | `PriceUnavailable` | `oracle_badAnswersRevert`, `buy_revertsOnStaleOrBrokenFeed` |
| Answer older than `maxPriceAge` | `StalePrice(updatedAt, maxAge)`; boundary exact | `oracle_staleAnswerReverts`, fuzz `staleness_boundary` |
| L2 sequencer down | `SequencerDown` | `oracle_sequencerDownAndGracePeriod` |
| Sequencer restarted < 1 hour ago, or invalid round (`startedAt` = 0) | `SequencerGracePeriod(upSince)` | same |
| Feed decimals 0-18 | scaled to 8 exactly; > 18 rejected when set; an answer that scales to 0 reverts | `oracle_feedDecimalsScaled`, `tinyHighDecimalAnswerRoundingToZeroReverts`, fuzz `feedDecimals_*` |
| Broken feed reports an absurd price | charge capped by `maxNativeCharge` -> `NativeChargeAboveCap` | `nativeCap_blocksAbsurdChargeFromBrokenFeed`, `buy_nativeCapBlocksAbsurdCharge` |
| No source configured | paid actions revert `PriceUnavailable`; free tier works | `oracle_noSourceConfigured` |
| Feed down | paid sends pause; 1-5 wallet sends keep working (no oracle read for $0) | `oracle_paidSendRevertsButFreeSendWorksWhenFeedBroken`, `quote_freeTierIsAllZerosEvenWithBrokenFeed` |
| Chain without Chainlink (Elysium) | manual price set by the owner, same caps | `oracle_manualMode`, `buy_manualPriceMode` |
| Misconfiguration | feed requires `maxAge > 0`; manual mode rejects a sequencer or max age; non-feed address reverts; `SetPricing.s.sol` checks `description()`, decimals, freshness and sequencer status on-chain before sending | `setPriceSource_validates`, local end-to-end run |

**Quotes.** `quote(walletCount)` returns `(feeNative, feeUsd, price, updatedAt)`; `quotePrice()` does the same for a Personal Multisend. Both return all zeros for free actions. The dapp sends the quote plus 2%; the contract charges the live price and refunds the rest.

**Refunds.** Paid with a raw `call` (no return-data copy) after all effects and payouts, under `nonReentrant`. A failing or re-entering refund recipient reverts the whole call (`payUpTo_refundFailureRevertsEverything`, `payUpTo_refundCannotReenter`, `buy_refundFailureRevertsWholePurchase`). Paying the exact amount skips the refund, so wallets that reject coins can still use the contract.

**Feeds (verify at deploy: `description()`, `decimals()`, recent answer).** Ethereum ETH/USD `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419`; BNB Chain BNB/USD `0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE`; Base ETH/USD `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` + sequencer `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433`; Arbitrum ETH/USD `0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612` + sequencer `0xFdB631F5EE196F0ed6FAa767959853A9F217697D`. HyperEVM HYPE/USD `0xa5a72eF19F82A579431186402425593a559ed352` (no sequencer: not a rollup); Robinhood Chain ETH/USD `0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9` (sequencer uptime feed not yet listed: add when available). Max age: 2h on Ethereum, BNB Chain, Base (observed update gaps <= 1h); 25h on Arbitrum, HyperEVM, Robinhood (deviation-driven, gaps of 2-4h observed, 24h heartbeat). Elysium: manual price.

## Limits

| Limit | Value | Enforced in | Tested |
| --- | --- | --- | --- |
| Recipients per call | 1 to 500 | `MultisendCore` (all contracts) | 500 passes, 501 reverts (native, token, personal) |
| Amount per recipient | > 0, total must not overflow `uint256` | `MultisendCore` | zero reverts with line index; `type(uint128).max` single send works; overflow reverts |
| Recipient address | not zero | `MultisendCore` | reverts with line index |
| Fee tiers | 1 to 5, ascending, last = 500 | `BulmoMultisend` | 1 and 5 accepted; 0, 6, unsorted, short, zero-bound rejected |
| Dollar fee / price cap | <= `type(uint224).max`; only decreases | constructors + setters | yes |
| Native charge cap | any value; only decreases | `UsdPricing` | yes (unit, fuzz, invariant) |
| Oracle age | `maxPriceAge` > 0 for a feed; sequencer grace 1 hour | `UsdPricing` | boundaries exact |
| Team wallets per Personal Multisend | 0 to 5 | `BulmoPersonalMultisend` | 6th reverts; removing frees a slot |
| Recipients per transaction in the Bulmo app | 250 (40 on HyperEVM) | app batching | stays under each chain's block gas limit |

## Optional extra: fee change delay

Today a dollar-price change takes effect immediately. Users are protected because they sign a maximum and get any difference back, and dollar fees can't exceed the cap. A stricter option is a **timelock**: changes are announced on-chain and only apply after e.g. 24 hours. Not implemented today.

## Accounting checks

| Property | How it is guaranteed | Tested by |
| --- | --- | --- |
| Main contract never holds coins; treasury gets every fee | payouts, fee forwarding and refund all in the same call | invariant `neverHoldsNativeAndTreasuryGotEveryFee` (random prices, treasury switches) |
| Overpayment always returned to the wei | refund = `msg.value - required` | invariants `refundsExactAndChargesCapped`, `refundsExact`; fuzz `exactPayoutsAndRefund` |
| No contract ever holds user tokens | tokens move with `transferFrom(sender, recipient)` directly | invariants `neverHoldsTokens`, `personalContractsHoldNothing` |
| Recipients receive exactly what was sent | sum and per-recipient checks across random sequences | invariants `recipientsReceivedEverything`, fuzz `exactPayouts` |
| Factory never holds coins; treasury gets every sale | charges `currentPrice()`, forwards it, refunds the rest; no `receive` | invariant `neverHoldsNativeAndTreasuryGotEverySale` |
| Conversion never undercharges | `mulDiv(..., Ceil)`; overcharge < 1 wei | fuzz `usdToNative_ceilWithinOneWei` |
| Fee / price never above cap; cap only falls | checked in every setter; clamping on cap reduction | invariants `feeNeverAboveCap`, `capOnlyDecreases` (both contracts) |
| No surprise charge | never more than the signed `msg.value`, never more than the live price; caps in USD and native | `revertsIfFeeRaisedAfterReview`, `feeLoweredAfterReviewChargesLess`, `payUpTo_*` |
| Every list size has a price | last tier must equal `MAX_RECIPIENTS` | `rejectsBadTables`, fuzz `feeFor_matchesTable` |
| Overflow | checked arithmetic (`total += amount`, `total + fee`) | `revertsOnAmountOverflow` |

## Access control checks

- Main contract and factory: `Ownable2Step`, `renounceOwnership` disabled. Owner powers limited to pricing (within caps), the price source, the treasury address, rescuing stray tokens or forced coins. No pause, no upgrade. A compromised owner can redirect future fees but cannot touch user funds or charge users more than they sign.
- Personal Multisend: only owner + up to 5 operators can send; operators send from **their own** wallet only and cannot manage, rescue or transfer ownership; Bulmo has no powers at all (`test_personal_bulmoHasNoPowerOverIt`).
- Clones: EIP-1167 (no admin, not upgradeable); initialised in the creating transaction; implementation locked by `_disableInitializers` (invariant `implementationStaysLocked`).
- Clone address derived from `(buyer, salt)`: nobody can claim another buyer's address (`test_buy_nobodyCanTakeABuyersAddress`).

## Gas and griefing checks

| Case | Result |
| --- | --- |
| Recipient rejects coins / burns all gas | whole send reverts, sender keeps everything (only the sender's own list is affected) |
| Re-entering recipient or token (ERC-777-style hooks) | blocked by `nonReentrant` |
| USDT-style (no return value), false-returning, non-contract, tax tokens | handled by `SafeERC20`; tax tokens deliver less, nothing stuck |
| Blocklisted recipient (e.g. USDC blacklist) | transfer reverts, whole send reverts |
| Fee lookup cost | at most 5 storage reads (packed `Tier` = 1 slot each) plus 1-2 oracle reads for paid sends (~10-15k gas) |
| Malicious or broken feed | can only make paid sends revert or cost up to `maxNativeCharge`; cannot touch user funds or free sends |
| 250 recipients (fresh wallets) | native ~9.61M gas, token ~7.63M gas; Personal clone creation ~0.2M gas |
| Block limits | dapp batches stay under each chain's limit (HyperEVM small blocks: 40) |

## Operational recommendations

1. Independent third-party audit (scope is small: about 530 lines of production code).
2. Owner = multisig (Safe) on every chain; confirm Safe availability on HyperEVM, Robinhood Chain and Elysium.
3. Run `make test-deep` before any deployment and verify every deployment on its explorer.
4. On each chain run `SetPricing.s.sol` right after deploy: it checks the feed on-chain, sets the source, and suggests a native cap (~$300 worth). Lower `maxNativeCharge` to leave room for the coin falling (the cap only goes down).
5. Elysium: keep the manual HYPE price current (or move to a Chainlink feed when one launches); consider a monitoring bot that alerts when it drifts more than a few percent.
