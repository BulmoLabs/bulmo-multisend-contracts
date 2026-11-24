#!/usr/bin/env bash
# Checks that the code deployed on every chain is exactly the code this repository builds.
#
#   script/verify-bytecode.sh                      # all 7 chains, public RPC endpoints
#   CHAINS="base arbitrum" script/verify-bytecode.sh
#
# Needs Foundry (forge, cast) and jq. Reads only public chain data; signs and sends nothing.
set -uo pipefail
cd "$(dirname "$0")/.."

declare -A RPC=(
  [ethereum]=https://ethereum-rpc.publicnode.com
  [bnb]=https://bsc-dataseed.bnbchain.org
  [base]=https://mainnet.base.org
  [arbitrum]=https://arb1.arbitrum.io/rpc
  [hyperevm]=https://rpc.hyperliquid.xyz/evm
  [robinhood]=https://rpc.mainnet.chain.robinhood.com
  [elysium]=https://rpc.elysium.kinetiq.xyz
)
MULTISEND=0xEF37b4902AD3eDc923112BD47C0D776bd2A419B3
FACTORY=0xC90079E3C00671B13a8f85d2FC2c9E9A0F3305D9
PERSONAL=0xFd5602187ce9Cd6c53C8469BBB518eBe913b2896

forge build -q >/dev/null || { echo "forge build failed"; exit 1; }

# The factory keeps the clone implementation address as an immutable, which the compiler leaves as
# zeros in the build output. Fill it with PERSONAL, so the check also proves which implementation
# every Personal Multisend clone runs.
expected() { # contract
  local code word s l
  code=$(jq -r .deployedBytecode.object "out/$1.sol/$1.json" | tr 'A-F' 'a-f')
  word=$(printf '%064s' "$(echo "${PERSONAL#0x}" | tr 'A-F' 'a-f')" | tr ' ' 0)
  for r in $(jq -r '.deployedBytecode.immutableReferences // {} | .[][] | "\(.start),\(.length)"' "out/$1.sol/$1.json"); do
    s=${r%,*}; l=${r#*,}
    code="${code:0:$((2 + 2 * s))}${word}${code:$((2 + 2 * s + 2 * l))}"
  done
  echo "$code"
}

failed=0
for chain in ${CHAINS:-ethereum bnb base arbitrum hyperevm robinhood elysium}; do
  for pair in BulmoMultisend:$MULTISEND BulmoMultisendFactory:$FACTORY BulmoPersonalMultisend:$PERSONAL; do
    name=${pair%%:*}; addr=${pair#*:}
    onchain=$(cast code "$addr" --rpc-url "${RPC[$chain]}" 2>/dev/null | tr 'A-F' 'a-f')
    if [ -z "$onchain" ]; then result="RPC ERROR"; failed=1
    elif [ "$onchain" = "$(expected "$name")" ]; then result="MATCH"
    else result="DIFFERENT"; failed=1; fi
    printf '%-10s %-24s %s  %s\n' "$chain" "$name" "$addr" "$result"
  done
done
[ $failed -eq 0 ] && echo "All deployed code matches this repository." || echo "Some checks did not match (see above)."
exit $failed
