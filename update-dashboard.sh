#!/bin/bash
# Dashboard data updater — runs every 30 min via cron
# Collects data from PM bot, HL engine, funding arb, momentum, copy signals

cd /home/ubuntu/clawd

# Update AI Fund prices
# AI Fund removed from dashboard

python3 << 'PYEOF'
import json, datetime, os, subprocess, re, glob

now = datetime.datetime.now(datetime.timezone.utc)

# ── PM Balance (from bot log) ──
pm_balance = 0
try:
    with open("/home/ubuntu/clawd/polymarket-assistant/trading.log") as f:
        for line in f:
            if "CLOB Balance:" in line or "Proxy Balance:" in line:
                m = re.search(r"\$([\d.]+)", line)
                if m: pm_balance = float(m.group(1))
except: pass

# ── HL Balance + Positions ──
hl_balance = 0
hl_positions = []
try:
    import requests
    # Query BOTH HL wallets and combine
    # Old wallet (HYPERLIQUID_PRIVATE_KEY): has positions
    resp = requests.post("https://api.hyperliquid.xyz/info", json={
        "type": "clearinghouseState",
        "user": "0x51F290588E0fB3107D9cde00984fA16f3dDA3191"
    }, timeout=10)
    hl_data_old = resp.json()
    hl_balance_old = float(hl_data_old["marginSummary"]["accountValue"])
    
    # New wallet (hl.js seed phrase): trading wallet
    resp2 = requests.post("https://api.hyperliquid.xyz/info", json={
        "type": "clearinghouseState",
        "user": "0x4Bf93279060fB5f71D40Ee7165D9f17535b0a2ba"
    }, timeout=10)
    hl_data_new = resp2.json()
    hl_balance_new = float(hl_data_new["marginSummary"]["accountValue"])
    
    # Combined
    hl_balance = hl_balance_old + hl_balance_new
    hl_data = hl_data_old  # Use old wallet for positions (it has the active ones)
    
    # Merge positions from both wallets
    for p in hl_data_old.get("assetPositions", []):
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
            "leverage": lev,
            "wallet": "old"
        })
    for p in hl_data_new.get("assetPositions", []):
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
            "leverage": lev,
            "wallet": "new"
        })
    # (old single-wallet block removed — both wallets handled above)
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
p1_directional_skew = 0.0
p1_order_flow_skew = 0.0
p1_directional_gap = 0.0
p1_avg_signal_price = 0.0
p1_structure_note = ""
p1_disagreement = False
p1_bearish_disagreement = False
p1_all_buy_bearish_disagreement = False
p1_all_buy_bearish_inversion = False
p1_max_gap_all_buy_bearish_disagreement = False
p1_max_gap_all_buy_bearish_inversion = False
p1_weak_directional_disagreement = False
p1_persistent_neutral_disagreement = False
p1_sell_heavy_bullish_disagreement = False
p1_flat_order_bearish_disagreement = False
p1_expensive_mixed_bearish = False
p1_aligned_bearish_crowded = False
p1_aligned_bullish_crowded = False
p1_crowded_expensive = False
p1_alignment_regime = "mixed"
p1_summary_state = "mixed_bullish"
p1_summary_text = "Mixed bullish copy flow"
p1_source_scan_time = None
p1_source_age_minutes = None
p1_lag_risk = False
p1_insights = []
try:
    with open("/home/ubuntu/clawd/intelligence/live-signals.json") as f:
        sig = json.load(f)
    p1_bias = sig.get("market_bias", "neutral")
    p1_confidence = sig.get("confidence", 0)
    suggested_adjustments = sig.get("suggested_adjustments", {}) or {}
    p1_structure_note = suggested_adjustments.get("structure_note", "")
    sources = sig.get("sources", {}) or {}
    p1_source_scan_time = sources.get("copy_signals_scan_time")
    if p1_source_scan_time:
        try:
            scan_dt = datetime.datetime.fromisoformat(p1_source_scan_time)
            p1_source_age_minutes = round((now - scan_dt).total_seconds() / 60, 1)
            p1_lag_risk = p1_source_age_minutes >= 15
        except Exception:
            p1_source_age_minutes = None
            p1_lag_risk = False
    details = sig.get("details", {})
    sa = details.get("signal_analysis", {})
    p1_signals_today = sa.get("signal_count", 0)
    p1_directional_skew = sa.get("directional_skew", 0.0) or 0.0
    p1_order_flow_skew = sa.get("order_flow_skew", 0.0) or 0.0
    p1_directional_gap = abs(p1_order_flow_skew - p1_directional_skew)
    p1_avg_signal_price = sa.get("avg_signal_price", 0.0) or 0.0
    p1_disagreement = bool(p1_structure_note)
    p1_bearish_disagreement = p1_disagreement and p1_directional_skew <= -0.50
    p1_crowded_expensive = p1_avg_signal_price >= 0.95 and abs(p1_directional_skew) >= 0.75
    p1_all_buy_bearish_disagreement = (
        p1_disagreement
        and p1_directional_skew <= -0.75
        and sa.get("buy_count", 0) == sa.get("signal_count", 0)
        and sa.get("signal_count", 0) >= 20
        and p1_avg_signal_price >= 0.98
    )
    p1_max_gap_all_buy_bearish_disagreement = (
        p1_all_buy_bearish_disagreement
        and p1_directional_skew <= -0.95
        and p1_directional_gap >= 1.90
    )
    p1_max_gap_all_buy_bearish_inversion = (
        not p1_all_buy_bearish_disagreement
        and p1_disagreement
        and sa.get("buy_count", 0) == sa.get("signal_count", 0)
        and sa.get("signal_count", 0) >= 20
        and p1_directional_skew <= -0.95
        and p1_directional_gap >= 1.90
    )
    p1_all_buy_bearish_inversion = (
        not p1_all_buy_bearish_disagreement
        and p1_disagreement
        and sa.get("buy_count", 0) == sa.get("signal_count", 0)
        and sa.get("signal_count", 0) >= 20
        and p1_directional_skew <= -0.85
        and p1_avg_signal_price >= 0.94
        and p1_directional_gap >= 1.50
    )
    p1_weak_directional_disagreement = (
        p1_disagreement
        and abs(p1_directional_skew) <= 0.20
        and p1_directional_gap >= 0.90
        and sa.get("signal_count", 0) >= 20
    )
    p1_persistent_neutral_disagreement = (
        p1_bias == "neutral"
        and p1_confidence <= 10
        and abs(p1_directional_skew) <= 0.10
        and sa.get("signal_count", 0) >= 20
        and (
            sig.get("alignment_regime") == "persistent_neutral_disagreement"
            or p1_source_age_minutes is not None and p1_source_age_minutes >= 20
        )
    )
    p1_sell_heavy_bullish_disagreement = (
        p1_disagreement
        and p1_directional_skew >= 0.60
        and p1_order_flow_skew <= -0.40
        and p1_directional_gap >= 1.00
        and p1_confidence < 50
        and sa.get("signal_count", 0) >= 20
    )
    p1_flat_order_bearish_disagreement = (
        p1_disagreement
        and p1_directional_skew <= -0.60
        and abs(p1_order_flow_skew) <= 0.10
        and p1_directional_gap >= 0.60
        and sa.get("signal_count", 0) >= 20
    )
    p1_expensive_mixed_bearish = (
        not p1_all_buy_bearish_disagreement
        and p1_avg_signal_price >= 0.98
        and p1_directional_skew <= -0.35
        and sa.get("signal_count", 0) >= 20
    )
    p1_aligned_bearish_crowded = p1_crowded_expensive and p1_directional_skew <= -0.75 and p1_order_flow_skew <= -0.75
    p1_aligned_bullish_crowded = p1_crowded_expensive and p1_directional_skew >= 0.75 and p1_order_flow_skew >= 0.75
    if p1_max_gap_all_buy_bearish_disagreement:
        p1_alignment_regime = "max_gap_all_buy_bearish_disagreement"
    elif p1_max_gap_all_buy_bearish_inversion:
        p1_alignment_regime = "max_gap_all_buy_bearish_inversion"
    elif p1_all_buy_bearish_inversion:
        p1_alignment_regime = "all_buy_bearish_inversion"
    elif p1_all_buy_bearish_disagreement:
        p1_alignment_regime = "all_buy_bearish_disagreement"
    elif p1_weak_directional_disagreement:
        p1_alignment_regime = "weak_directional_disagreement"
    elif p1_persistent_neutral_disagreement:
        p1_alignment_regime = "persistent_neutral_disagreement"
    elif p1_sell_heavy_bullish_disagreement:
        p1_alignment_regime = "sell_heavy_bullish_disagreement"
    elif p1_flat_order_bearish_disagreement:
        p1_alignment_regime = "flat_order_bearish_disagreement"
    elif p1_aligned_bearish_crowded:
        p1_alignment_regime = "aligned_bearish_crowded"
    elif p1_aligned_bullish_crowded:
        p1_alignment_regime = "aligned_bullish_crowded"
    elif not p1_disagreement and not p1_crowded_expensive and abs(p1_directional_skew) >= 0.75 and abs(p1_order_flow_skew - p1_directional_skew) <= 0.10:
        p1_alignment_regime = "aligned_high_conviction"
    elif p1_bearish_disagreement:
        p1_alignment_regime = "bearish_disagreement"
    elif p1_disagreement:
        p1_alignment_regime = "disagreement"
    elif p1_expensive_mixed_bearish:
        p1_alignment_regime = "expensive_mixed_bearish"
    elif p1_crowded_expensive:
        p1_alignment_regime = "crowded_expensive"
    else:
        p1_alignment_regime = "mixed"
    if p1_alignment_regime == "max_gap_all_buy_bearish_disagreement":
        p1_summary_state = "max_gap_all_buy_bearish_disagreement"
        p1_summary_text = "Max-gap all-buy bearish disagreement in copy flow"
    elif p1_alignment_regime == "max_gap_all_buy_bearish_inversion":
        p1_summary_state = "max_gap_all_buy_bearish_inversion"
        p1_summary_text = "Max-gap all-buy bearish inversion in copy flow"
    elif p1_alignment_regime == "all_buy_bearish_inversion":
        p1_summary_state = "all_buy_bearish_inversion"
        p1_summary_text = "All-buy bearish inversion in copy flow"
    elif p1_alignment_regime == "all_buy_bearish_disagreement":
        p1_summary_state = "all_buy_bearish_disagreement"
        p1_summary_text = "All-buy bearish disagreement in copy flow"
    elif p1_alignment_regime == "aligned_bearish_crowded":
        p1_summary_state = "aligned_bearish_crowded"
        p1_summary_text = "Aligned bearish crowded copy flow"
    elif p1_alignment_regime == "aligned_bullish_crowded":
        p1_summary_state = "aligned_bullish_crowded"
        p1_summary_text = "Aligned bullish crowded copy flow"
    elif p1_alignment_regime == "aligned_high_conviction":
        p1_summary_state = f"aligned_{p1_bias}"
        p1_summary_text = f"Aligned {p1_bias} copy flow"
    elif p1_alignment_regime == "crowded_expensive":
        p1_summary_state = f"crowded_{p1_bias}"
        p1_summary_text = f"Crowded expensive {p1_bias} copy flow"
    elif p1_alignment_regime == "weak_directional_disagreement":
        p1_summary_state = "weak_directional_disagreement"
        p1_summary_text = "Weak-direction disagreement in copy flow"
    elif p1_alignment_regime == "persistent_neutral_disagreement":
        p1_summary_state = "persistent_neutral_disagreement"
        p1_summary_text = "Persistent neutral disagreement in copy flow"
    elif p1_alignment_regime == "sell_heavy_bullish_disagreement":
        p1_summary_state = "sell_heavy_bullish_disagreement"
        p1_summary_text = "Sell-heavy bullish disagreement in copy flow"
    elif p1_alignment_regime == "flat_order_bearish_disagreement":
        p1_summary_state = "flat_order_bearish_disagreement"
        p1_summary_text = "Flat-order bearish disagreement in copy flow"
    elif p1_alignment_regime == "expensive_mixed_bearish":
        p1_summary_state = "expensive_mixed_bearish"
        p1_summary_text = "Expensive mixed bearish copy flow"
    elif p1_alignment_regime == "bearish_disagreement":
        p1_summary_state = "bearish_disagreement"
        p1_summary_text = "Bearish disagreement regime in copy flow"
    elif p1_alignment_regime == "disagreement":
        p1_summary_state = "disagreement"
        p1_summary_text = "Disagreement regime in copy flow"
    else:
        p1_summary_state = f"mixed_{p1_bias}"
        p1_summary_text = f"Mixed {p1_bias} copy flow"

    if p1_lag_risk:
        p1_summary_text += " — lagging source"

    if sa.get("buy_count", 0) + sa.get("sell_count", 0) > 0:
        p1_insights.append({
            "source": "Copy Scanner",
            "text": f"Top traders: {sa.get('buy_count',0)} buys, {sa.get('sell_count',0)} sells — avg price ${sa.get('avg_signal_price',0):.3f}"
        })
    if p1_max_gap_all_buy_bearish_disagreement:
        p1_insights.append({
            "source": "Copy Structure",
            "text": f"🧩 max-gap all-buy bearish disagreement: directional skew {p1_directional_skew:+.2f}, order-flow skew {p1_order_flow_skew:+.2f}, avg price ${p1_avg_signal_price:.3f}, gap {p1_directional_gap:.2f}"
        })
    elif p1_max_gap_all_buy_bearish_inversion:
        p1_insights.append({
            "source": "Copy Structure",
            "text": f"🧩 max-gap all-buy bearish inversion: directional skew {p1_directional_skew:+.2f}, order-flow skew {p1_order_flow_skew:+.2f}, avg price ${p1_avg_signal_price:.3f}, gap {p1_directional_gap:.2f}"
        })
    elif p1_all_buy_bearish_inversion:
        p1_insights.append({
            "source": "Copy Structure",
            "text": f"🧩 all-buy bearish inversion: directional skew {p1_directional_skew:+.2f}, order-flow skew {p1_order_flow_skew:+.2f}, avg price ${p1_avg_signal_price:.3f}, gap {p1_directional_gap:.2f}"
        })
    elif p1_all_buy_bearish_disagreement:
        p1_insights.append({
            "source": "Copy Structure",
            "text": f"🧩 all-buy bearish disagreement: directional skew {p1_directional_skew:+.2f}, order-flow skew {p1_order_flow_skew:+.2f}, avg price ${p1_avg_signal_price:.3f}, gap {p1_directional_gap:.2f}"
        })
    elif p1_aligned_bearish_crowded:
        p1_insights.append({
            "source": "Copy Structure",
            "text": f"💸 aligned bearish crowding: directional skew {p1_directional_skew:+.2f}, order-flow skew {p1_order_flow_skew:+.2f}, avg price ${p1_avg_signal_price:.3f}"
        })
    elif p1_aligned_bullish_crowded:
        p1_insights.append({
            "source": "Copy Structure",
            "text": f"💸 aligned bullish crowding: directional skew {p1_directional_skew:+.2f}, order-flow skew {p1_order_flow_skew:+.2f}, avg price ${p1_avg_signal_price:.3f}"
        })
    elif p1_flat_order_bearish_disagreement:
        p1_insights.append({
            "source": "Copy Structure",
            "text": f"🧩 flat-order bearish disagreement: directional skew {p1_directional_skew:+.2f}, order-flow skew {p1_order_flow_skew:+.2f}, gap {p1_directional_gap:.2f}"
        })
    elif p1_bearish_disagreement:
        p1_insights.append({
            "source": "Copy Structure",
            "text": f"🧩 bearish disagreement: directional skew {p1_directional_skew:+.2f} vs order-flow skew {p1_order_flow_skew:+.2f} (gap {p1_directional_gap:.2f})"
        })
    elif p1_weak_directional_disagreement:
        p1_insights.append({
            "source": "Copy Structure",
            "text": f"🧩 weak-direction disagreement: directional skew {p1_directional_skew:+.2f}, order-flow skew {p1_order_flow_skew:+.2f}, gap {p1_directional_gap:.2f}"
        })
    elif p1_persistent_neutral_disagreement:
        p1_insights.append({
            "source": "Copy Structure",
            "text": f"🧩 persistent neutral disagreement: directional skew {p1_directional_skew:+.2f}, order-flow skew {p1_order_flow_skew:+.2f}, confidence {p1_confidence}, source_age {p1_source_age_minutes:.1f}m"
        })
    elif p1_sell_heavy_bullish_disagreement:
        p1_insights.append({
            "source": "Copy Structure",
            "text": f"🧩 sell-heavy bullish disagreement: directional skew {p1_directional_skew:+.2f}, order-flow skew {p1_order_flow_skew:+.2f}, gap {p1_directional_gap:.2f}, confidence {p1_confidence}"
        })
    elif p1_expensive_mixed_bearish:
        p1_insights.append({
            "source": "Copy Structure",
            "text": f"💸 expensive mixed bearish: directional skew {p1_directional_skew:+.2f}, order-flow skew {p1_order_flow_skew:+.2f}, avg price ${p1_avg_signal_price:.3f}"
        })
    elif p1_disagreement:
        p1_insights.append({
            "source": "Copy Structure",
            "text": f"🧩 disagreement regime: directional skew {p1_directional_skew:+.2f} vs order-flow skew {p1_order_flow_skew:+.2f} (gap {p1_directional_gap:.2f})"
        })
    if p1_source_age_minutes is not None:
        p1_insights.append({
            "source": "Copy Freshness",
            "text": f"⏱️ source scan age: {p1_source_age_minutes:.1f}m" + (" — lag risk" if p1_lag_risk else "")
        })
    if p1_crowded_expensive:
        p1_insights.append({
            "source": "Copy Structure",
            "text": f"💸 crowded regime: directional skew {p1_directional_skew:+.2f} at avg price ${p1_avg_signal_price:.3f}"
        })
    if p1_alignment_regime == "aligned_high_conviction":
        p1_insights.append({
            "source": "Copy Structure",
            "text": f"✅ aligned regime: directional skew {p1_directional_skew:+.2f}, order-flow skew {p1_order_flow_skew:+.2f}, avg price ${p1_avg_signal_price:.3f}"
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
pm_pnl = pm_balance - 1009.32  # PM capital: $488 original + $1000 new - $478.68 stuck (not trading loss)

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
        "status": "SHELVED",
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

# ── Historical P&L (from actual trade outcomes, not balance diffs) ──
daily_pnl = []
try:
    import glob
    outcomes_file = "/home/ubuntu/clawd/polymarket-assistant/confidence_outcomes.jsonl"
    by_date = {}
    historical = {"2026-03-16": -15.0, "2026-03-17": -20.0, "2026-03-18": -10.0, "2026-03-19": -5.0}
    for line in open(outcomes_file):
        line = line.strip()
        if not line: continue
        o = json.loads(line)
        date = o['ts'][:10]
        if date not in by_date:
            by_date[date] = 0.0
        entry = o.get('entry_price', 0.5)
        size = o.get('size_usd', 20)
        if o.get('won', False):
            by_date[date] += size * (1.0/entry - 1.0)
        else:
            by_date[date] -= size
    all_dates = sorted(set(list(historical.keys()) + list(by_date.keys())))
    for date in all_dates:
        pnl = by_date.get(date, historical.get(date, 0))
        daily_pnl.append({"date": date, "pnl": round(pnl, 2)})
    daily_pnl = daily_pnl[-14:]
    
    # Fix today stats from outcomes
    today_str = now.strftime("%Y-%m-%d")
    today_outcomes = [json.loads(l) for l in open(outcomes_file) if l.strip() and today_str in l]
    today_trades = len(today_outcomes)
    today_wins = sum(1 for o in today_outcomes if o.get('won'))
    today_losses = today_trades - today_wins
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

# ── Read dynamic pillar data ──
_pscores = {}
try:
    with open("/home/ubuntu/clawd/dashboard/pillar-scores.json") as _pf:
        _pscores = json.load(_pf)
except: pass

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
                        "impact_class": "green" if chr(10004) in _pe.get("impact","") else "red" if chr(128308) in _pe.get("impact","") else "cyan"
                    })
    for k in _pevents: _pevents[k] = _pevents[k][-10:]
except: pass

data = {
    "timestamp": now.isoformat(),
    "pm_balance": pm_balance,
    "hl_balance": hl_balance,
    "today_pnl": round(sum(daily_pnl[-1:][0]['pnl'] for _ in [1]) if daily_pnl and daily_pnl[-1]['date'] == now.strftime('%Y-%m-%d') else 0, 2),
    "pm_pnl": round(pm_balance - 1009.32, 2),
    "hl_pnl": round(hl_balance - 391.0, 2),
    "today_trades": today_trades,
    "today_wins": today_wins,
    "today_losses": today_losses,
    "all_time_pnl": round((pm_balance + hl_balance) - (1009.32 + 391.0), 2),  # Deposits minus stuck: PM_init=$1009.32 HL_init=$391
    "total_trades": total_trades,
    "days_active": (now - datetime.datetime(2026, 3, 15, tzinfo=datetime.timezone.utc)).days,
    "pm_bot_running": subprocess.run(["pgrep", "-f", "trading_bot.py"], capture_output=True).returncode == 0,
    "hl_bot_running": subprocess.run(["pgrep", "-f", "hl_trading_engine"], capture_output=True).returncode == 0,
    "hl_positions": hl_positions,
    "funding_opportunities": funding_opps,
    "daily_pnl": daily_pnl,
    
    # ═══ PILLAR 1: Copy Intelligence ═══
    "pillar1": {
        "completion": _pscores.get("p1", 60),
        "traders_tracked": p1_traders,
        "current_bias": p1_bias,
        "signal_confidence": p1_confidence,
        "signals_today": p1_signals_today,
        "directional_skew": round(p1_directional_skew, 3),
        "order_flow_skew": round(p1_order_flow_skew, 3),
        "directional_order_gap": round(p1_directional_gap, 3),
        "avg_signal_price": round(p1_avg_signal_price, 3),
        "alignment_regime": p1_alignment_regime,
        "summary_state": p1_summary_state,
        "summary_text": p1_summary_text,
        "source_scan_time": p1_source_scan_time,
        "source_age_minutes": p1_source_age_minutes,
        "lag_risk": p1_lag_risk,
        "disagreement_regime": p1_disagreement,
        "bearish_disagreement_regime": p1_bearish_disagreement,
        "all_buy_bearish_disagreement_regime": p1_all_buy_bearish_disagreement,
        "all_buy_bearish_inversion_regime": p1_all_buy_bearish_inversion,
        "max_gap_all_buy_bearish_disagreement_regime": p1_max_gap_all_buy_bearish_disagreement,
        "max_gap_all_buy_bearish_inversion_regime": p1_max_gap_all_buy_bearish_inversion,
        "weak_directional_disagreement_regime": p1_weak_directional_disagreement,
        "persistent_neutral_disagreement_regime": p1_persistent_neutral_disagreement,
        "sell_heavy_bullish_disagreement_regime": p1_sell_heavy_bullish_disagreement,
        "flat_order_bearish_disagreement_regime": p1_flat_order_bearish_disagreement,
        "expensive_mixed_bearish_regime": p1_expensive_mixed_bearish,
        "aligned_bearish_crowded_regime": p1_aligned_bearish_crowded,
        "aligned_bullish_crowded_regime": p1_aligned_bullish_crowded,
        "crowded_expensive_regime": p1_crowded_expensive,
        "structure_note": p1_structure_note,
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
    
    # ═══ WORK LOG ═══
    "worklog": open("/home/ubuntu/clawd/WORKLOG.md").read()[:3000] if os.path.exists("/home/ubuntu/clawd/WORKLOG.md") else "",
    
    # ═══ PILLAR 4: Alpha Research Pipeline ═══
    "pillar4": {
        "completion": 15,
        "data_sources": 4,
        "signals_generated": 0,
        "research_files": len(glob.glob("/home/ubuntu/clawd/research/*.md")),
        "sources": [
            {"name": "HL Leaderboard Tracker", "status": "ACTIVE", "last_signal": p1_bias.upper() + " consensus"},
            {"name": "PM Leaderboard Scraper", "status": "ACTIVE", "last_signal": "Top 20 profit leaders tracked"},
            {"name": "Funding Rate Scanner", "status": "ACTIVE", "last_signal": f"{len(funding_opps)} opportunities"},
            {"name": "SolSt1ne Content", "status": "BUILDING", "last_signal": "—"},
            {"name": "On-Chain Flows", "status": "PLANNED", "last_signal": "—"},
            {"name": "Fear & Greed Index", "status": "PLANNED", "last_signal": "—"},
        ],
    },
}

with open("/home/ubuntu/clawd/dashboard/data.json", 'w') as f:
    json.dump(data, f, indent=2)

p1_headline = p1_summary_state + ("!lag" if p1_lag_risk else "")
print(f"Dashboard: PM=${pm_balance:.2f} HL=${hl_balance:.2f} | {total_trades} trades | WR={pm_win_rate:.0f}% | P1:{p1_headline} P2:{len(strategies)} strats P3:{params_changed} changes")
PYEOF

# Push to GitHub
cd /home/ubuntu/clawd/dashboard
git add -A 2>/dev/null
git commit -m "update $(date -u +%Y-%m-%dT%H:%M)" --allow-empty 2>/dev/null
git push origin main 2>/dev/null

# Deploy to brainai.bot
scp -o ConnectTimeout=5 /home/ubuntu/clawd/dashboard/index.html /home/ubuntu/clawd/dashboard/data.json ubuntu@13.53.199.22:~/brainai-hq-v2/public/braintrade-dashboard/ 2>/dev/null
