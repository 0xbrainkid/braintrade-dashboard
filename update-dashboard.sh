#!/bin/bash
# Dashboard data updater — runs every 30 min via cron
# Collects data from PM bot, HL engine, funding arb, momentum, copy signals

cd /home/ubuntu/clawd

python3 << 'PYEOF'
import json, datetime, os, subprocess, re, glob

now = datetime.datetime.now(datetime.timezone.utc)

# ── PM Balance (from bot log) ──
pm_balance = 0
try:
    with open("/home/ubuntu/clawd/polymarket-assistant/trading.log") as f:
        for line in f:
            if "Proxy Balance:" in line:
                m = re.search(r"\$([\d.]+)", line)
                if m: pm_balance = float(m.group(1))
except: pass

# ── HL Balance + Positions ──
hl_balance = 0
hl_positions = []
try:
    import requests
    resp = requests.post("https://api.hyperliquid.xyz/info", json={
        "type": "clearinghouseState",
        "user": "0x4Bf93279060fB5f71D40Ee7165D9f17535b0a2ba"
    }, timeout=10)
    hl_data = resp.json()
    hl_balance = float(hl_data["marginSummary"]["accountValue"])
    for p in hl_data.get("assetPositions", []):
        pos = p["position"]
        szi = float(pos["szi"])
        if szi == 0: continue
        lev = 10
        try:
            if isinstance(pos.get("leverage"), dict):
                lev = int(float(pos["leverage"].get("value", 10)))
        except: pass
        hl_positions.append({
            "coin": pos["coin"],
            "side": "LONG" if szi > 0 else "SHORT",
            "size": abs(szi),
            "entry": float(pos["entryPx"]),
            "pnl": float(pos["unrealizedPnl"]),
            "leverage": lev
        })
except Exception as e:
    print(f"HL error: {e}")

# ── Trade stats from log ──
today_str = now.strftime("%Y-%m-%d")
total_trades = 0
today_trades = 0
today_yes = 0; today_no = 0
all_prices = []
try:
    with open("/home/ubuntu/clawd/polymarket-assistant/trading.log") as f:
        for line in f:
            if "TRADE EXECUTED" in line:
                total_trades += 1
                if today_str in line:
                    today_trades += 1
                    if "YES" in line: today_yes += 1
                    else: today_no += 1
                m = re.search(r"@ ([\d.]+)", line)
                if m: all_prices.append(float(m.group(1)))
except: pass

# ── Outcome stats ──
today_wins = 0; today_losses = 0
all_wins = 0; all_losses = 0
recent_wins = 0; recent_total = 0  # last 20 trades
outcomes = []
try:
    with open("/home/ubuntu/clawd/polymarket-assistant/confidence_outcomes.jsonl") as f:
        for line in f:
            if not line.strip(): continue
            o = json.loads(line)
            outcomes.append(o)
            won = o.get("won", False)
            if won: all_wins += 1
            else: all_losses += 1
            if today_str in o.get("ts", ""):
                if won: today_wins += 1
                else: today_losses += 1
    # Last 20
    for o in outcomes[-20:]:
        recent_total += 1
        if o.get("won"): recent_wins += 1
except: pass

# ── Copy Signals (Pillar 1) ──
p1_traders = 0
p1_bias = "neutral"
p1_confidence = 0
p1_signals_today = 0
p1_insights = []
try:
    with open("/home/ubuntu/clawd/intelligence/live-signals.json") as f:
        sig = json.load(f)
    p1_bias = sig.get("market_bias", "neutral")
    p1_confidence = sig.get("confidence", 0)
    details = sig.get("details", {})
    sa = details.get("signal_analysis", {})
    p1_signals_today = sa.get("signal_count", 0)
    if sa.get("buy_count", 0) + sa.get("sell_count", 0) > 0:
        p1_insights.append({
            "source": "Copy Scanner",
            "text": f"Top traders: {sa.get('buy_count',0)} buys, {sa.get('sell_count',0)} sells — avg price ${sa.get('avg_signal_price',0):.3f}"
        })
except: pass

try:
    signals_files = glob.glob("/home/ubuntu/clawd/intelligence/copy-signals*.json")
    if signals_files:
        with open(sorted(signals_files)[-1]) as f:
            sigs = json.load(f)
            if isinstance(sigs, list):
                p1_traders = len(set(s.get("wallet","")[:10] for s in sigs if s.get("wallet")))
except: pass

# Funding rate insights
try:
    import requests
    resp = requests.post("https://api.hyperliquid.xyz/info", json={"type": "metaAndAssetCtxs"}, timeout=10)
    meta, ctxs = resp.json()
    top_funding = []
    for i, ctx in enumerate(ctxs):
        coin = meta['universe'][i]['name']
        funding = float(ctx.get('funding', 0))
        oi = float(ctx.get('openInterest', 0))
        if abs(funding) > 0.0005 and oi > 500000:
            top_funding.append((coin, funding, oi))
    top_funding.sort(key=lambda x: abs(x[1]), reverse=True)
    if top_funding:
        top = top_funding[0]
        direction = "shorts paying longs" if top[1] < 0 else "longs paying shorts"
        p1_insights.append({
            "source": "Funding Intel",
            "text": f"Strongest: {top[0]} at {top[1]*100:.4f}%/8h — {direction}"
        })
        neg_count = sum(1 for _,f,_ in top_funding if f < 0)
        pos_count = sum(1 for _,f,_ in top_funding if f > 0)
        p1_insights.append({
            "source": "Market Sentiment",
            "text": f"{neg_count} coins with negative funding (bearish), {pos_count} positive (bullish) — market leans {'bearish' if neg_count > pos_count else 'bullish'}"
        })
except: pass

# Research file count
research_count = len(glob.glob("/home/ubuntu/clawd/research/trader-analysis-*.md"))
reports_count = len(glob.glob("/home/ubuntu/clawd/reports/daily-pnl-*.md"))

# ── Pillar 1 evolution ──
p1_evolution = [
    {"date": "Mar 15", "change": "PM copy scanner built — tracking top wallets", "impact": "NEW", "impact_class": "cyan"},
    {"date": "Mar 19", "change": "SolSt1ne 4-stack strategy extracted (Kelly + conviction + divergence + AI)", "impact": "EDGE", "impact_class": "green"},
    {"date": "Mar 20", "change": "Copy signals wired into bot as conviction boost", "impact": "+1 conv", "impact_class": "green"},
    {"date": "Mar 20", "change": f"Funding rate scanner: {len(top_funding) if 'top_funding' in dir() else 0} opportunities identified", "impact": "INTEL", "impact_class": "cyan"},
]

# ── Strategy Performance (Pillar 2) ──
pm_win_rate = (all_wins / (all_wins + all_losses) * 100) if (all_wins + all_losses) > 0 else 0
pm_pnl = pm_balance - 406.925  # initial PM balance

strategies = [
    {
        "name": "PM Smart Entry",
        "status": "LIVE" if subprocess.run(["pgrep", "-f", "trading_bot.py"], capture_output=True).returncode == 0 else "DOWN",
        "trades": total_trades,
        "win_rate": round(pm_win_rate, 1),
        "pnl": pm_pnl,
        "sharpe": 0.0
    },
    {
        "name": "HL Directional",
        "status": "LIVE" if subprocess.run(["pgrep", "-f", "hl_trading_engine"], capture_output=True).returncode == 0 else "DOWN",
        "trades": len(hl_positions),
        "win_rate": 0,
        "pnl": sum(p["pnl"] for p in hl_positions),
        "sharpe": 0.0
    },
    {
        "name": "HL Funding Arb",
        "status": "READY",
        "trades": 0,
        "win_rate": 0,
        "pnl": 0.0,
        "sharpe": 0.0
    },
    {
        "name": "HL Momentum",
        "status": "DRY-RUN" if subprocess.run(["pgrep", "-f", "hl_momentum"], capture_output=True).returncode == 0 else "OFF",
        "trades": 0,
        "win_rate": 0,
        "pnl": 0.0,
        "sharpe": 0.0
    }
]

# Sharpe from log
try:
    with open("/home/ubuntu/clawd/polymarket-assistant/sharpe_log.jsonl") as f:
        lines = f.readlines()
    if lines:
        last = json.loads(lines[-1])
        strategies[0]["sharpe"] = round(last.get("sharpe", 0), 2)
except: pass

p2_edge_history = [
    {"date": "Mar 15", "change": "PM bot launched — basic bias score only", "impact": "55% WR", "impact_class": "yellow"},
    {"date": "Mar 16", "change": "Added min price filter ($0.50) + entry delay (60s)", "impact": "+6% WR", "impact_class": "green"},
    {"date": "Mar 19", "change": "SolSt1ne upgrade: Kelly sizing, conviction 3/4, divergence 8%, confidence 62%", "impact": "MAJOR", "impact_class": "green"},
    {"date": "Mar 20", "change": f"Fixed min_price $0.65→$0.50 (was blocking all trades)", "impact": "FIX", "impact_class": "yellow"},
    {"date": "Mar 20", "change": "Built HL Funding Rate Arb + HL Momentum strategies", "impact": "+2 strats", "impact_class": "green"},
]

# ── Pillar 3: Iteration ──
# Count parameter changes from memory
params_changed = 6  # min_price x2, entry_delay, kelly_fraction, conviction_min, divergence_threshold

p3_changes = [
    {"date": "Mar 16", "param": "min_price", "old": "none", "new": "$0.50", "reason": "Prices <$0.50 = losers"},
    {"date": "Mar 16", "param": "entry_delay", "old": "0s", "new": "60s", "reason": "First 60s = coin flip"},
    {"date": "Mar 19", "param": "kelly_fraction", "old": "0.10", "new": "0.25", "reason": "SolSt1ne: half-Kelly"},
    {"date": "Mar 19", "param": "conviction_min", "old": "2", "new": "3", "reason": "SolSt1ne: stack edges"},
    {"date": "Mar 19", "param": "divergence_threshold", "old": "0.0", "new": "0.08", "reason": "SolSt1ne: 8% AI filter"},
    {"date": "Mar 20", "param": "min_price", "old": "$0.65", "new": "$0.50", "reason": "Was blocking all trades"},
]

win_rate_24h = round(today_wins / (today_wins + today_losses) * 100, 1) if (today_wins + today_losses) > 0 else 0
win_rate_7d = round(all_wins / (all_wins + all_losses) * 100, 1) if (all_wins + all_losses) > 0 else 0
avg_trade = round(sum(all_prices) / len(all_prices), 2) if all_prices else 0
max_dd = 0
try:
    # Calculate max drawdown from daily P&L
    old_data = json.load(open("/home/ubuntu/clawd/dashboard/data.json"))
    cum = 0
    peak = 0
    for d in old_data.get("daily_pnl", []):
        cum += d["pnl"]
        if cum > peak: peak = cum
        dd = (peak - cum) / max(peak, 1) * 100 if peak > 0 else 0
        if dd > max_dd: max_dd = dd
except: pass

# ── Historical P&L ──
daily_pnl = []
try:
    old = json.load(open("/home/ubuntu/clawd/dashboard/data.json"))
    daily_pnl = old.get("daily_pnl", [])
    today_label = now.strftime("%m/%d")
    today_only = pm_pnl + sum(p["pnl"] for p in hl_positions)
    prev_pnl = sum(d['pnl'] for d in daily_pnl if d['date'] != today_label)
    today_only = today_only - prev_pnl
    found = False
    for d in daily_pnl:
        if d['date'] == today_label:
            d['pnl'] = today_only
            found = True
    if not found:
        daily_pnl.append({"date": today_label, "pnl": today_only})
    daily_pnl = daily_pnl[-14:]
except: pass

# ── Funding Opportunities ──
funding_opps = []
try:
    if 'top_funding' in dir() and top_funding:
        for coin, funding, oi in top_funding[:10]:
            apr = funding * 3 * 365 * 100
            funding_opps.append({
                "coin": coin,
                "rate": f"{funding*100:+.4f}%",
                "apr": f"{apr:+.0f}%",
                "action": "SHORT" if funding > 0 else "LONG",
                "oi": f"{oi:,.0f}"
            })
except: pass

# ── Build Output ──
data = {
    "timestamp": now.isoformat(),
    "pm_balance": pm_balance,
    "hl_balance": hl_balance,
    "today_pnl": pm_pnl + sum(p["pnl"] for p in hl_positions),
    "pm_pnl": pm_pnl,
    "hl_pnl": sum(p["pnl"] for p in hl_positions),
    "today_trades": today_trades,
    "today_wins": today_wins,
    "today_losses": today_losses,
    "all_time_pnl": (pm_balance + hl_balance) - (406.925 + 399.315),
    "total_trades": total_trades,
    "days_active": (now - datetime.datetime(2026, 3, 15, tzinfo=datetime.timezone.utc)).days,
    "pm_bot_running": subprocess.run(["pgrep", "-f", "trading_bot.py"], capture_output=True).returncode == 0,
    "hl_bot_running": subprocess.run(["pgrep", "-f", "hl_trading_engine"], capture_output=True).returncode == 0,
    "hl_positions": hl_positions,
    "funding_opportunities": funding_opps,
    "daily_pnl": daily_pnl,
    
    # ═══ PILLAR 1: Copy Intelligence ═══
    # Read dynamic scores
    _pscores = {}
    try:
        with open("/home/ubuntu/clawd/dashboard/pillar-scores.json") as _pf:
            _pscores = json.load(_pf)
    except: pass
    # Read recent pillar events
    _pevents = {"1": [], "2": [], "3": []}
    try:
        with open("/home/ubuntu/clawd/dashboard/pillar-log.jsonl") as _plf:
            for _pline in _plf:
                if _pline.strip():
                    _pe = json.loads(_pline)
                    p = str(_pe.get("pillar", 0))
                    if p in _pevents:
                        _pevents[p].append({
                            "date": _pe["ts"][:10].replace("2026-",""),
                            "change": _pe["action"],
                            "impact": _pe.get("impact",""),
                            "impact_class": "green" if "✅" in _pe.get("impact","") else "red" if "🔴" in _pe.get("impact","") else "cyan"
                        })
        # Keep last 10 per pillar
        for k in _pevents: _pevents[k] = _pevents[k][-10:]
    except: pass

    "pillar1": {
        "completion": _pscores.get("p1", 60),
        "traders_tracked": p1_traders,
        "current_bias": p1_bias,
        "signal_confidence": p1_confidence,
        "signals_today": p1_signals_today,
        "insights": p1_insights,
        "evolution": _pevents.get("1", []),
    },
    
    # ═══ PILLAR 2: Edge Development ═══
    "pillar2": {
        "completion": _pscores.get("p2", 55),
        "strategies": strategies,
        "edge_history": _pevents.get("2", []),
    },
    
    # ═══ PILLAR 3: Continuous Iteration ═══
    "pillar3": {
        "completion": _pscores.get("p3", 65),
        "params_changed": params_changed,
        "research_reports": research_count + reports_count,
        "heartbeats_today": 0,  # TODO: count from logs
        "changes": _pevents.get("3", []),
        "win_rate_7d": win_rate_7d,
        "win_rate_24h": win_rate_24h,
        "avg_trade_size": avg_trade,
        "sharpe": strategies[0]["sharpe"],
        "max_drawdown": round(max_dd, 1),
    },
}

with open("/home/ubuntu/clawd/dashboard/data.json", 'w') as f:
    json.dump(data, f, indent=2)

print(f"Dashboard: PM=${pm_balance:.2f} HL=${hl_balance:.2f} | {total_trades} trades | WR={pm_win_rate:.0f}% | P1:{p1_bias} P2:{len(strategies)} strats P3:{params_changed} changes")
PYEOF

# Push to GitHub
cd /home/ubuntu/clawd/dashboard
git add -A 2>/dev/null
git commit -m "update $(date -u +%Y-%m-%dT%H:%M)" --allow-empty 2>/dev/null
git push origin main 2>/dev/null

# Deploy to brainai.bot
scp -o ConnectTimeout=5 /home/ubuntu/clawd/dashboard/index.html /home/ubuntu/clawd/dashboard/data.json ubuntu@16.16.78.208:~/brainai-hq-v2/public/braintrade-dashboard/ 2>/dev/null
