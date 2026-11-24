# Deploying Bulmo Multisend

Operator guide: how the contracts were deployed to the same addresses on every chain, and how to deploy them to a new one.


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

