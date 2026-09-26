#!/usr/bin/env bash
# Off-chain keeper for the Holster Uniswap v4 hook.
# Reads needsPoke() for free every INTERVAL seconds and sends poke() only when it returns true.
# The hook also runs the same check before every swap, so the keeper is optional: it pays the gas of
# re-placement instead of the next swapper, and keeps the positions up to date between swaps.
# poke() can be called by anyone, so any funded account works.
#
#   RPC_URL=https://sepolia.base.org ACCOUNT=<cast keystore name> ./keeper/poke.sh
#
# Without HOOKS, it watches the demo pools in contracts/deployments/ (Holster and the band-off pool) and re-reads
# them every round, so it follows a new deployment. HOOKS="0x... 0x..." watches the given hooks instead.
#
# The keystore password is asked once at start.
set -euo pipefail

FIXED_HOOKS="${HOOKS:-${HOOK:-}}"
CHAIN_ID="${CHAIN_ID:-84532}"
DEPLOYMENTS="$(cd "$(dirname "$0")/.." && pwd)/contracts/deployments"
: "${RPC_URL:?set RPC_URL}"
: "${ACCOUNT:?set ACCOUNT to a cast keystore account}"
INTERVAL="${INTERVAL:-60}"

KEYSTORE="$HOME/.foundry/keystores/$ACCOUNT"
[[ -f "$KEYSTORE" ]] || { echo "keystore not found: $KEYSTORE"; exit 1; }
# Kept in a shell variable, not exported: an exported ETH_PASSWORD makes every cast command ask for a keystore.
PASSWORD="${ETH_PASSWORD:-}"
unset ETH_PASSWORD
if [[ -z "$PASSWORD" ]]; then
  read -rsp "Keystore password for $ACCOUNT: " PASSWORD
  echo
fi
# The hooks to watch: HOOKS if given, otherwise the latest demo deployment.
hooks() {
  if [[ -n "$FIXED_HOOKS" ]]; then echo "$FIXED_HOOKS"; return; fi
  for f in "$DEPLOYMENTS/v4-$CHAIN_ID.json" "$DEPLOYMENTS/v4-baseline-$CHAIN_ID.json"; do
    [[ -f "$f" ]] && grep -o '"hook": *"0x[0-9a-fA-F]*"' "$f" | grep -o '0x[0-9a-fA-F]*'
  done
}
echo "watching $(hooks | tr '\n' ' ')every ${INTERVAL}s"

while true; do
  for hook in $(hooks); do
    if ! needs="$(cast call "$hook" 'needsPoke()(bool)' --rpc-url "$RPC_URL" 2>&1)"; then
      echo "$(date -u +%FT%TZ) $hook read failed: $needs"
    elif [[ "$needs" == "true" ]]; then
      echo "$(date -u +%FT%TZ) $hook needsPoke=true -> poke()"
      if out="$(cast send "$hook" 'poke()' --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" 2>&1)"; then
        echo "  done: $(grep -m1 transactionHash <<<"$out" || true)"
      else
        echo "  failed: $out"
      fi
    fi
  done
  sleep "$INTERVAL"
done
