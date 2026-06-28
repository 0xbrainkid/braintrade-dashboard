#!/usr/bin/env bash
set -euo pipefail

cd /home/ubuntu/clawd/dashboard
node scripts/update-options-quotes.mjs

if git diff --quiet -- options-dashboard/quotes.json; then
  exit 0
fi

git add options-dashboard/quotes.json
git commit -m "Update options quotes"
git push origin main
