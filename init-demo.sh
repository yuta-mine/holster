#!/usr/bin/env bash
# Starts the v4 demo over on Base Sepolia: new demo tokens, a router, and two pools at 1.00 with liquidity
# (Holster, and the same pool with the band off), then points the frontend at them.
#
#   ./init-demo.sh                      # uses the `deployer` keystore
#   ACCOUNT=<keystore> ./init-demo.sh
#
# A keeper started without HOOKS (./keeper/poke.sh) follows the new pools on its own.
set -euo pipefail
cd "$(dirname "$0")"

RPC_URL="${RPC_URL:-https://sepolia.base.org}"
ACCOUNT="${ACCOUNT:-deployer}"

(cd contracts && forge script script/DeployV4.s.sol --rpc-url "$RPC_URL" --account "$ACCOUNT" --broadcast)
node frontend/sync-config.mjs 84532

echo
echo "Done. Reload the demo page. The public page needs a new deploy of frontend/ to pick up the addresses."
