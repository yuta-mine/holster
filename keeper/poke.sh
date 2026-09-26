#!/usr/bin/env bash
# Off-chain keeper for the Holster Uniswap v4 hook.
# Reads needsPoke() for free every INTERVAL seconds and sends poke() only when it returns true.
# The hook also runs the same check before every swap, so the keeper is optional: it pays the gas of
# re-placement instead of the next swapper, and keeps the positions up to date between swaps.
#
#   HOOK=0x... RPC_URL=https://sepolia.base.org ACCOUNT=<cast keystore name> ./keeper/poke.sh
set -euo pipefail

: "${HOOK:?set HOOK to the HolsterHook address}"
: "${RPC_URL:?set RPC_URL}"
: "${ACCOUNT:?set ACCOUNT to a cast keystore account}"
INTERVAL="${INTERVAL:-60}"

while true; do
  if [[ "$(cast call "$HOOK" 'needsPoke()(bool)' --rpc-url "$RPC_URL")" == "true" ]]; then
    echo "$(date -u +%FT%TZ) needsPoke=true -> poke()"
    cast send "$HOOK" 'poke()' --rpc-url "$RPC_URL" --account "$ACCOUNT"
  fi
  sleep "$INTERVAL"
done
