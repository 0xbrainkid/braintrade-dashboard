#!/usr/bin/env bash
set -euo pipefail

# brainai.bot/fund1-dashboard is served from the canonical Fund1 source tree.
# Do not update the stale dashboard/options-dashboard copy from this directory.
exec /home/ubuntu/clawd/agents/polymarket/fund1-dashboard/scripts/update-options-live.sh
