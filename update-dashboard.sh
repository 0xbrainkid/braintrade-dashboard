#!/bin/bash
# brainTrade Dashboard Data Updater
# Runs every 30 min via cron, generates data.json for the dashboard

DASH_DIR="/home/ubuntu/clawd/dashboard"
PROXY="0x2e6325f52CF4c0F77c719296f1A4332557B393C2"
HL_WALLET="0x4Bf93279060fB5f71D40Ee7165D9f17535b0a2ba"

python3 << 'PYEOF'
import json, time, datetime, requests, sys, os

PROXY = os.environ.get("PROXY", "0x2e6325f52CF4c0F77c719296f1A4332557B393C2")
HL_WALLET = os.environ.get("HL_WALLET", "0x4Bf93279060fB5f71D40Ee7165D9f17535b0a2ba")
DASH_DIR = os.environ.get("DASH_DIR", "/home/ubuntu/clawd/dashboard")

now = time.time()
today_start = int(datetime.datetime.now(datetime.timezone.utc).replace(hour=0, minute=0, second=0).timestamp())

data = {
    "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "pm_balance": 0, "hl_balance": 0,
    "today_pnl": 0, "pm_pnl": 0, "hl_pnl": 0,
    "today_trades": 0, "today_wins": 0, "today_losses": 0,
    "all_time_pnl": 0, "total_trades": 0, "days_active": 0,
    "pm_bot_running": False, "hl_bot_running": False,
    "daily_pnl": []
}

# PM Balance via RPC
try:
    rpc = {
        'jsonrpc': '2.0', 'method': 'eth_call',
        'params': [{
            'to': '0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174',
            'data': '0x70a08231000000000000000000000000' + PROXY[2:]
        }, 'latest'], 'id': 1
    }
    resp = requests.post('https://polygon-bor-rpc.publicnode.com', json=rpc, timeout=10)
    if resp.status_code == 200:
        result = resp.json().get('result', '0x0')
        data["pm_balance"] = int(result, 16) / 1e6
except: pass

# HL Balance via API
try:
    resp = requests.post('https://api.hyperliquid.xyz/info', 
                         json={"type": "clearinghouseState", "user": HL_WALLET}, timeout=10)
    if resp.status_code == 200:
        state = resp.json()
        data["hl_balance"] = float(state.get("marginSummary", {}).get("accountValue", 0))
except: pass

# PM Activity (today)
try:
    resp = requests.get(f"https://data-api.polymarket.com/activity?user={PROXY}&limit=500", timeout=15)
    if resp.status_code == 200:
        items = resp.json()
        trades = [i for i in items if i['type'] == 'TRADE' and i['timestamp'] >= today_start]
        redeems = [i for i in items if i['type'] == 'REDEEM' and i['timestamp'] >= today_start]
        all_trades = [i for i in items if i['type'] == 'TRADE']
        all_redeems = [i for i in items if i['type'] == 'REDEEM']
        
        # Today's trades
        from collections import defaultdict
        markets = defaultdict(lambda: {'spent': 0, 'redeemed': 0})
        for t in trades:
            markets[t['conditionId']]['spent'] += t['usdcSize']
        for r in redeems:
            if r['timestamp'] >= today_start:
                markets[r['conditionId']]['redeemed'] += r['usdcSize']
        
        for cid, m in markets.items():
            data["today_trades"] += 1
            if m['redeemed'] > m['spent'] * 0.5:
                data["today_wins"] += 1
            else:
                data["today_losses"] += 1
        
        today_spent = sum(m['spent'] for m in markets.values())
        today_back = sum(m['redeemed'] for m in markets.values())
        data["pm_pnl"] = today_back - today_spent
        
        # All-time
        all_markets = defaultdict(lambda: {'spent': 0, 'redeemed': 0})
        for t in all_trades:
            all_markets[t['conditionId']]['spent'] += t['usdcSize']
        for r in all_redeems:
            all_markets[r['conditionId']]['redeemed'] += r['usdcSize']
        
        total_spent = sum(m['spent'] for m in all_markets.values())
        total_back = sum(m['redeemed'] for m in all_markets.values())
        data["all_time_pnl"] = total_back - total_spent
        data["total_trades"] = len(all_markets)
        
        # Daily P&L (last 7 days)
        for day_offset in range(6, -1, -1):
            day = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=day_offset)
            day_start = int(day.replace(hour=0, minute=0, second=0).timestamp())
            day_end = day_start + 86400
            
            day_markets = defaultdict(lambda: {'spent': 0, 'redeemed': 0})
            for t in all_trades:
                if day_start <= t['timestamp'] < day_end:
                    day_markets[t['conditionId']]['spent'] += t['usdcSize']
            for r in all_redeems:
                if day_start <= r['timestamp'] < day_end:
                    day_markets[r['conditionId']]['redeemed'] += r['usdcSize']
            
            if day_markets:
                d_spent = sum(m['spent'] for m in day_markets.values())
                d_back = sum(m['redeemed'] for m in day_markets.values())
                data["daily_pnl"].append({
                    "date": day.strftime("%m/%d"),
                    "pnl": d_back - d_spent
                })
        
        # Days active
        if all_trades:
            first = min(t['timestamp'] for t in all_trades)
            data["days_active"] = max(1, int((now - first) / 86400))
except Exception as e:
    print(f"PM data error: {e}", file=sys.stderr)

# HL P&L
try:
    resp = requests.post('https://api.hyperliquid.xyz/info',
                         json={"type": "clearinghouseState", "user": HL_WALLET}, timeout=10)
    if resp.status_code == 200:
        state = resp.json()
        positions = state.get("assetPositions", [])
        hl_upnl = sum(float(p["position"].get("unrealizedPnl", 0)) for p in positions)
        data["hl_pnl"] = hl_upnl
except: pass

data["today_pnl"] = data["pm_pnl"] + data["hl_pnl"]

# Check if bots are running
import subprocess
try:
    result = subprocess.run(['pgrep', '-f', 'trading_bot.py'], capture_output=True)
    data["pm_bot_running"] = result.returncode == 0
except: pass
try:
    result = subprocess.run(['pgrep', '-f', 'hl_trading_engine.py'], capture_output=True)
    data["hl_bot_running"] = result.returncode == 0
except: pass

# Write data.json
output = os.path.join(DASH_DIR, "data.json")
with open(output, 'w') as f:
    json.dump(data, f, indent=2)

print(f"Dashboard updated: PM=${data['pm_balance']:.2f} HL=${data['hl_balance']:.2f} PnL=${data['today_pnl']:+.2f}")
PYEOF

# Auto-push to GitHub Pages
cd /home/ubuntu/clawd/dashboard
git add data.json 2>/dev/null
git commit -m "update $(date -u +%Y-%m-%dT%H:%M)" --allow-empty 2>/dev/null
git push origin main 2>/dev/null
