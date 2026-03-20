#!/bin/bash
# Dashboard data updater — runs every 30 min via cron
# Collects data from PM bot, HL engine, funding arb, momentum

cd /home/ubuntu/clawd

python3 << 'PYEOF'
import json, datetime, os, subprocess, requests

now = datetime.datetime.now(datetime.timezone.utc)

# ── PM Balance ──
pm_balance = 0
# Fallback: read from bot log
try:
    import re
    with open("/home/ubuntu/clawd/polymarket-assistant/trading.log") as f:
        for line in f:
            if "Proxy Balance:" in line:
                m = re.search(r"\$([\d.]+)", line)
                if m: pm_balance = float(m.group(1))
except: pass
try:
    proxy = os.environ.get("PROXY", "0x2e6325f52CF4c0F77c719296f1A4332557B393C2")
    resp = requests.post("https://polygon-rpc.com", json={
        "jsonrpc": "2.0", "method": "eth_call",
        "params": [{"to": "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174",
                     "data": "0x70a08231000000000000000000000000" + proxy.replace("0x","")}, "latest"],
        "id": 1}, timeout=10)
    pm_balance = int(resp.json()["result"], 16) / 1e6
except: pass

# ── HL Balance + Positions ──
hl_balance = 0
hl_positions = []
try:
    resp = requests.post("https://api.hyperliquid.xyz/info", json={
        "type": "clearinghouseState",
        "user": os.environ.get("HL_WALLET", "0x4Bf93279060fB5f71D40Ee7165D9f17535b0a2ba")
    }, timeout=10)
    hl_data = resp.json()
    hl_balance = float(hl_data["marginSummary"]["accountValue"])
    for p in hl_data.get("assetPositions", []):
        pos = p["position"]
        szi = float(pos["szi"])
        if szi == 0: continue
        hl_positions.append({
            "coin": pos["coin"],
            "side": "LONG" if szi > 0 else "SHORT",
            "size": abs(szi),
            "entry": float(pos["entryPx"]),
            "pnl": float(pos["unrealizedPnl"]),
            "leverage": int(float(pos.get("leverage", {}).get("value", 1))) if isinstance(pos.get("leverage"), dict) else 10
        })
except Exception as e:
    print(f"HL error: {e}")

# ── PM Trades Today ──
today_str = now.strftime("%Y-%m-%d")
today_trades = 0; today_wins = 0; today_losses = 0
try:
    log = open("/home/ubuntu/clawd/polymarket-assistant/trading.log").read()
    today_trades = log.count(f"{today_str}") and sum(1 for l in log.split('\n') if today_str in l and "TRADE EXECUTED" in l)
    outcomes = open("/home/ubuntu/clawd/polymarket-assistant/confidence_outcomes.jsonl").read()
    for line in outcomes.strip().split('\n'):
        if not line: continue
        o = json.loads(line)
        if today_str in o.get("ts", ""):
            if o.get("won"): today_wins += 1
            else: today_losses += 1
except: pass

# ── Funding Opportunities ──
funding_opps = []
try:
    resp = requests.post("https://api.hyperliquid.xyz/info", json={"type": "metaAndAssetCtxs"}, timeout=10)
    meta, ctxs = resp.json()
    for i, ctx in enumerate(ctxs):
        coin = meta['universe'][i]['name']
        funding = float(ctx.get('funding', 0))
        oi = float(ctx.get('openInterest', 0))
        if abs(funding) > 0.0001 and oi > 500000:
            apr = funding * 3 * 365 * 100
            funding_opps.append({
                "coin": coin,
                "rate": f"{funding*100:+.4f}%",
                "apr": f"{apr:+.0f}%",
                "action": "SHORT" if funding > 0 else "LONG",
                "oi": f"{oi:,.0f}"
            })
    funding_opps.sort(key=lambda x: abs(float(x['apr'].replace('%','').replace('+',''))), reverse=True)
except: pass

# ── Strategy Status ──
strategies = {
    "funding_arb": "READY",
    "momentum": "DRY-RUN"
}
try:
    if subprocess.run(["pgrep", "-f", "hl_funding_arb"], capture_output=True).returncode == 0:
        strategies["funding_arb"] = "LIVE"
    if subprocess.run(["pgrep", "-f", "hl_momentum"], capture_output=True).returncode == 0:
        strategies["momentum"] = "DRY-RUN"
except: pass

# ── Historical P&L ──
daily_pnl = []
try:
    old = json.load(open("/home/ubuntu/clawd/dashboard/data.json"))
    daily_pnl = old.get("daily_pnl", [])
    # Update today's entry
    today_label = now.strftime("%m/%d")
    initial_pm = 406.925  # Starting PM balance
    initial_hl = 399.315  # Starting HL balance
    pm_pnl = pm_balance - initial_pm
    hl_pnl = hl_balance - initial_hl
    today_pnl_val = pm_pnl + hl_pnl
    
    # Subtract previous days' PnL to get today only
    prev_pnl = sum(d['pnl'] for d in daily_pnl if d['date'] != today_label)
    today_only = today_pnl_val - prev_pnl
    
    found = False
    for d in daily_pnl:
        if d['date'] == today_label:
            d['pnl'] = today_only
            found = True
    if not found:
        daily_pnl.append({"date": today_label, "pnl": today_only})
    # Keep last 14 days
    daily_pnl = daily_pnl[-14:]
except: pass

# ── Build Output ──
data = {
    "timestamp": now.isoformat(),
    "pm_balance": pm_balance,
    "hl_balance": hl_balance,
    "today_pnl": sum(p.get("pnl", 0) for p in hl_positions) + (pm_balance - 406.925),
    "pm_pnl": pm_balance - 406.925,
    "hl_pnl": sum(p.get("pnl", 0) for p in hl_positions),
    "today_trades": today_trades,
    "today_wins": today_wins,
    "today_losses": today_losses,
    "all_time_pnl": (pm_balance + hl_balance) - (406.925 + 399.315),
    "total_trades": 113 + today_trades,
    "days_active": (now - datetime.datetime(2026, 3, 15, tzinfo=datetime.timezone.utc)).days,
    "pm_bot_running": subprocess.run(["pgrep", "-f", "trading_bot.py"], capture_output=True).returncode == 0,
    "hl_bot_running": subprocess.run(["pgrep", "-f", "hl_trading_engine"], capture_output=True).returncode == 0,
    "strategies": strategies,
    "hl_positions": hl_positions,
    "funding_opportunities": funding_opps[:10],
    "daily_pnl": daily_pnl
}

dash_dir = os.environ.get("DASH_DIR", "/home/ubuntu/clawd/dashboard")
with open(f"{dash_dir}/data.json", 'w') as f:
    json.dump(data, f, indent=2)

print(f"Dashboard: PM=${pm_balance:.2f} HL=${hl_balance:.2f} | {len(hl_positions)} positions | {len(funding_opps)} funding opps")
PYEOF

# Push to GitHub
cd ${DASH_DIR:-/home/ubuntu/clawd/dashboard}
git add -A 2>/dev/null
git commit -m "update $(date -u +%Y-%m-%dT%H:%M)" --allow-empty 2>/dev/null
git push origin main 2>/dev/null

# Deploy to brainai.bot
scp -o ConnectTimeout=5 ${DASH_DIR:-/home/ubuntu/clawd/dashboard}/data.json ubuntu@16.16.78.208:~/brainai-hq-v2/public/braintrade-dashboard/ 2>/dev/null
