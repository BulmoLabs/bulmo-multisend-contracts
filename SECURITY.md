# Security policy

## Reporting a vulnerability

Please report security issues privately to **contact@bulmo.xyz**. Do not open a public GitHub issue.

Include the affected contract and chain, a description of the issue and, if possible, a proof of concept (a Foundry test is ideal). We will acknowledge your report and keep you updated on the fix.

## Scope

The contracts in [`src/`](src) as deployed at:

| Contract | Address (same on every chain) |
| --- | --- |
| `BulmoMultisend` | `0xEF37b4902AD3eDc923112BD47C0D776bd2A419B3` |
| `BulmoMultisendFactory` | `0xC90079E3C00671B13a8f85d2FC2c9E9A0F3305D9` |
| `BulmoPersonalMultisend` | `0xFd5602187ce9Cd6c53C8469BBB518eBe913b2896` |

Chains: Ethereum, BNB Chain, Base, Arbitrum One, HyperEVM, Robinhood Chain and Elysium.

The deployed contracts cannot be upgraded. See [SECURITY_REVIEW.md](SECURITY_REVIEW.md) for the internal review and test results.
