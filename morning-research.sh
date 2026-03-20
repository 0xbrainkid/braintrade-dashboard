#!/bin/bash
# Morning Research — runs at 07:00 UTC via cron
cd /home/ubuntu/clawd

python3 << 'PYEOF'
import requests, json, datetime, os

now = datetime.datetime.now(datetime.timezone.utc)
date_str = now.strftime("%Y-%m-%d")

# Fetch HL leaderboard
try:
    resp = requests.post("https://api.hyperliquid.xyz/info", 
        json={"type": "leaderboard", "period": "day", "limit": 20}, timeout=10)
    hl_leaders = resp.json() if resp.ok else []
except:
    hl_leaders = []

# Fetch BTC market data
try:
    ticker = requests.get("https://api.binance.com/api/v3/ticker/24hr",
        params={"symbol": "BTCUSDT"}, timeout=10).json()
    btc_price = float(ticker['lastPrice'])
    btc_change = float(ticker['priceChangePercent'])
    btc_vol = float(ticker['volume'])
except:
    btc_price = btc_change = btc_vol = 0

# Fetch funding rates
try:
    funding = requests.get("https://fapi.binance.com/fapi/v1/fundingRate",
        params={"symbol": "BTCUSDT", "limit": 8}, timeout=5).json()
    funding_rates = [float(f['fundingRate'])*100 for f in funding]
except:
    funding_rates = []

# PM copy scanner results
try:
    with open("/home/ubuntu/clawd/intelligence/pm-top-traders.json") as f:
        pm_traders = json.load(f)
except:
    pm_traders = []

# Build report
report = f"""# Trader Analysis — {date_str}

## Market Context
- BTC: ${btc_price:,.0f} ({btc_change:+.1f}%)
- 24h Volume: {btc_vol:,.0f} BTC

## Funding Rates (last 8 periods)
{', '.join(f'{r:+.4f}%' for r in funding_rates) if funding_rates else 'unavailable'}
- Average: {sum(funding_rates)/len(funding_rates):+.4f}% per period

## HL Leaderboard (Top 20 Daily)
"""

if isinstance(hl_leaders, list):
    for i, leader in enumerate(hl_leaders[:20], 1):
        if isinstance(leader, dict):
            addr = leader.get('ethAddress', leader.get('user', '?'))[:10]
            pnl = leader.get('pnl', leader.get('windowPerformance', 0))
            report += f"{i}. {addr}... PnL: ${pnl:+,.2f}\n" if isinstance(pnl, (int,float)) else f"{i}. {addr}...\n"
else:
    report += "Leaderboard data unavailable\n"

report += f"""
## PM Top Traders
{json.dumps(pm_traders[:5], indent=2) if pm_traders else 'No data — run pm-copy-scanner.py'}

## Trading Insights
- Funding {'positive (longs paying)' if funding_rates and sum(funding_rates) > 0 else 'negative (shorts paying)' if funding_rates else 'unknown'}
- {'High volume day' if btc_vol > 30000 else 'Normal volume'}
- Market {'up' if btc_change > 0 else 'down'} {abs(btc_change):.1f}%

## Action Items
- [ ] Review top HL trader positions for copy signals
- [ ] Check PM patterns from copy scanner
- [ ] Adjust bot parameters if needed
"""

report_path = f"/home/ubuntu/clawd/research/trader-analysis-{date_str}.md"
with open(report_path, 'w') as f:
    f.write(report)
print(f"Research saved: {report_path}")
PYEOF
