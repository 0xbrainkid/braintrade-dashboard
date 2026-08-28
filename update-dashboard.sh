#!/bin/bash
# Dashboard data updater — runs every 30 min via cron
# Collects data from PM bot, HL engine, funding arb, momentum, copy signals

cd /home/ubuntu/clawd

# Update AI Fund prices
# AI Fund removed from dashboard

python3 << 'PYEOF'
import json, datetime, os, subprocess, re, glob, sys

sys.path.insert(0, '/home/ubuntu/clawd/hyperliquid-trader')
try:
    from hl_wallet_audit import audit_wallet_alignment, DEFAULT_FUNDED_WALLET
except Exception:
    audit_wallet_alignment = None
    DEFAULT_FUNDED_WALLET = "0x4Bf93279060fB5f71D40Ee7165D9f17535b0a2ba"

now = datetime.datetime.now(datetime.timezone.utc)


def process_running(*patterns):
    return any(
        subprocess.run(["pgrep", "-f", pattern], capture_output=True).returncode == 0
        for pattern in patterns
    )


def parse_state_timestamp(raw):
    if raw in (None, ""):
        return None
    if isinstance(raw, (int, float)):
        try:
            return datetime.datetime.fromtimestamp(float(raw), tz=datetime.timezone.utc)
        except Exception:
            return None
    if isinstance(raw, str):
        candidate = raw.strip()
        if candidate.endswith('Z'):
            candidate = candidate[:-1] + '+00:00'
        try:
            return datetime.datetime.fromisoformat(candidate)
        except Exception:
            try:
                return datetime.datetime.fromtimestamp(float(candidate), tz=datetime.timezone.utc)
            except Exception:
                return None
    return None


def load_state_health(path, stale_after_minutes=180):
    health = {
        "path": path,
        "exists": False,
        "last_updated": None,
        "age_minutes": None,
        "stale": True,
    }
    try:
        with open(path) as f:
            payload = json.load(f)
        health["exists"] = True
        ts = None
        if isinstance(payload, dict):
            ts = payload.get("timestamp")
            if ts in (None, ""):
                ts = payload.get("last_updated")
        dt = parse_state_timestamp(ts)
        if dt is not None:
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=datetime.timezone.utc)
            age_minutes = round((now - dt).total_seconds() / 60, 1)
            health.update({
                "last_updated": dt.isoformat(),
                "age_minutes": age_minutes,
                "stale": age_minutes >= stale_after_minutes,
            })
    except Exception as e:
        health["error"] = str(e)
    return health


def load_file_mtime_health(path, stale_after_minutes=15):
    health = {
        "path": path,
        "exists": False,
        "last_updated": None,
        "age_minutes": None,
        "stale": True,
    }
    try:
        stat = os.stat(path)
        dt = datetime.datetime.fromtimestamp(stat.st_mtime, tz=datetime.timezone.utc)
        age_minutes = round((now - dt).total_seconds() / 60, 1)
        health.update({
            "exists": True,
            "last_updated": dt.isoformat(),
            "age_minutes": age_minutes,
            "stale": age_minutes >= stale_after_minutes,
        })
    except Exception as e:
        health["error"] = str(e)
    return health


def annotate_state_owner(health, owner_name, *owner_patterns):
    annotated = dict(health)
    owner_running = process_running(*owner_patterns)
    annotated.update({
        "owner": owner_name,
        "owner_running": owner_running,
        "ownership_status": (
            "active" if owner_running and not health.get("stale", True)
            else "stale_but_running" if owner_running
            else "legacy_inactive" if health.get("exists")
            else "missing"
        ),
    })
    return annotated

prev_dashboard = {}
prev_p1 = {}
alpha_signal = {}
p4_transition_stability = {}
try:
    with open('/home/ubuntu/clawd/dashboard/data.json') as f:
        prev_dashboard = json.load(f)
        prev_p1 = prev_dashboard.get('pillar1', {}) or {}
except Exception:
    prev_dashboard = {}
    prev_p1 = {}

try:
    with open('/home/ubuntu/clawd/research/alpha-signals.json') as f:
        alpha_signal = json.load(f)
except Exception:
    alpha_signal = {}

try:
    _p4_stability_script = '/home/ubuntu/clawd/scripts/analyze_p4_alpha_transition_stability.py'
    if os.path.exists(_p4_stability_script):
        subprocess.run([_p4_stability_script], capture_output=True, timeout=10)
    with open('/home/ubuntu/clawd/research/p4-alpha-transition-stability.json') as f:
        p4_transition_stability = json.load(f)
except Exception:
    p4_transition_stability = {}

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
hl_wallet_alignment = {}
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

try:
    if audit_wallet_alignment:
        hl_wallet_alignment = audit_wallet_alignment(
            DEFAULT_FUNDED_WALLET,
            reference_wallet=DEFAULT_FUNDED_WALLET,
            min_funded_balance=10.0,
        )
except Exception as e:
    hl_wallet_alignment = {"error": str(e)}

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
p1_persistent_sell_heavy_bullish_disagreement = False
p1_soft_flat_order_bearish_disagreement = False
p1_persistent_soft_flat_order_bearish_disagreement = False
p1_flat_order_bearish_disagreement = False
p1_bearish_crowded_expensive = False
p1_anonymous_zero_spend_bearish_crowded_expensive = False
p1_mixed_transition_after_bearish_crowding = False
p1_flip_flop_extreme_copy_instability = False
p1_expensive_mixed_bearish = False
p1_aligned_bearish_crowded = False
p1_aligned_bullish_crowded = False
p1_crowded_expensive = False
p1_alignment_regime = "mixed"
p1_summary_state = "mixed_bullish"
p1_summary_text = "Mixed bullish copy flow"
p1_source_alignment_regime = None
p1_source_scan_time = None
p1_source_age_minutes = None
p1_lag_risk = False
p1_recent_strong_regime = prev_p1.get("recent_strong_regime")
p1_recent_strong_regime_seen_at = prev_p1.get("recent_strong_regime_seen_at")
p1_recent_strong_regime_age_minutes = prev_p1.get("recent_strong_regime_age_minutes")
p1_recent_strong_regime_source_scan_time = prev_p1.get("recent_strong_regime_source_scan_time")
p1_insights = []
try:
    with open("/home/ubuntu/clawd/intelligence/live-signals.json") as f:
        sig = json.load(f)
    p1_bias = sig.get("market_bias", "neutral")
    p1_confidence = sig.get("confidence", 0)
    p1_source_alignment_regime = sig.get("alignment_regime")
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
    prev_recent_seen_at = prev_p1.get("recent_strong_regime_seen_at")
    prev_recent_scan_time = prev_p1.get("recent_strong_regime_source_scan_time")
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
        (
            sig.get("alignment_regime") == "sell_heavy_bullish_disagreement"
            or sig.get("alignment_regime") == "persistent_sell_heavy_bullish_disagreement"
        )
        or (
            p1_disagreement
            and p1_directional_skew >= 0.60
            and p1_order_flow_skew <= -0.40
            and p1_directional_gap >= 1.00
            and sa.get("signal_count", 0) >= 20
        )
    )
    p1_persistent_sell_heavy_bullish_disagreement = (
        sig.get("alignment_regime") == "persistent_sell_heavy_bullish_disagreement"
        or ((sig.get("persistence", {}) or {}).get("persistent_sell_heavy_bullish_disagreement") is True)
    )
    p1_soft_flat_order_bearish_disagreement = (
        p1_directional_skew <= -0.35
        and abs(p1_order_flow_skew) <= 0.15
        and p1_directional_gap >= 0.25
        and p1_avg_signal_price >= 0.95
        and sa.get("signal_count", 0) >= 20
    )
    prev_p1_summary_state = prev_p1.get("summary_state")
    prev_p1_alignment_regime = prev_p1.get("alignment_regime")
    prev_p1_source_scan_time = prev_p1.get("source_scan_time")
    p1_persistent_soft_flat_order_bearish_disagreement = (
        p1_soft_flat_order_bearish_disagreement
        and p1_source_scan_time is not None
        and prev_p1_source_scan_time is not None
        and p1_source_scan_time != prev_p1_source_scan_time
        and prev_p1_alignment_regime in (
            "soft_flat_order_bearish_disagreement",
            "persistent_soft_flat_order_bearish_disagreement",
        )
    ) or (
        p1_soft_flat_order_bearish_disagreement
        and p1_source_scan_time is not None
        and prev_p1_source_scan_time is not None
        and p1_source_scan_time != prev_p1_source_scan_time
        and prev_p1_summary_state == "soft_flat_order_bearish_disagreement"
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
    p1_bearish_crowded_expensive = (
        p1_crowded_expensive
        and p1_directional_skew <= -0.75
        and p1_order_flow_skew <= -0.50
        and sa.get("signal_count", 0) >= 20
    )
    p1_anonymous_zero_spend_bearish_crowded_expensive = (
        p1_source_alignment_regime == "anonymous_zero_spend_bearish_crowded_expensive"
        or (
            p1_bearish_crowded_expensive
            and (sa.get("total_size", 0) or 0) <= 0
        )
    )
    p1_mixed_transition_after_bearish_crowding = (
        p1_source_alignment_regime == "mixed_transition_after_bearish_crowding"
    )
    p1_flip_flop_extreme_copy_instability = (
        p1_source_alignment_regime == "flip_flop_extreme_copy_instability"
        or ((sig.get("persistence", {}) or {}).get("flip_flop_extreme_copy_instability") is True)
    )
    p1_aligned_bearish_crowded = p1_crowded_expensive and p1_directional_skew <= -0.75 and p1_order_flow_skew <= -0.75
    p1_aligned_bullish_crowded = p1_crowded_expensive and p1_directional_skew >= 0.75 and p1_order_flow_skew >= 0.75
    if p1_source_alignment_regime == "anonymous_zero_spend_bearish_crowded_expensive" or p1_anonymous_zero_spend_bearish_crowded_expensive:
        p1_alignment_regime = "anonymous_zero_spend_bearish_crowded_expensive"
    elif p1_source_alignment_regime == "mixed_transition_after_bearish_crowding" or p1_mixed_transition_after_bearish_crowding:
        p1_alignment_regime = "mixed_transition_after_bearish_crowding"
    elif p1_source_alignment_regime == "flip_flop_extreme_copy_instability" or p1_flip_flop_extreme_copy_instability:
        p1_alignment_regime = "flip_flop_extreme_copy_instability"
    elif p1_max_gap_all_buy_bearish_disagreement:
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
    elif p1_persistent_sell_heavy_bullish_disagreement:
        p1_alignment_regime = "persistent_sell_heavy_bullish_disagreement"
    elif p1_sell_heavy_bullish_disagreement:
        p1_alignment_regime = "sell_heavy_bullish_disagreement"
    elif p1_persistent_soft_flat_order_bearish_disagreement:
        p1_alignment_regime = "persistent_soft_flat_order_bearish_disagreement"
    elif p1_soft_flat_order_bearish_disagreement:
        p1_alignment_regime = "soft_flat_order_bearish_disagreement"
    elif p1_flat_order_bearish_disagreement:
        p1_alignment_regime = "flat_order_bearish_disagreement"
    elif p1_bearish_crowded_expensive:
        p1_alignment_regime = "bearish_crowded_expensive"
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
    if p1_alignment_regime == "anonymous_zero_spend_bearish_crowded_expensive":
        p1_summary_state = "anonymous_zero_spend_bearish_crowded_expensive"
        p1_summary_text = "Anonymous zero-spend bearish crowded-expensive copy flow"
    elif p1_alignment_regime == "mixed_transition_after_bearish_crowding":
        p1_summary_state = "mixed_transition_after_bearish_crowding"
        p1_summary_text = "Mixed transition after bearish crowding"
    elif p1_alignment_regime == "flip_flop_extreme_copy_instability":
        p1_summary_state = "flip_flop_extreme_copy_instability"
        p1_summary_text = "Flip-flop extreme copy instability"
    elif p1_alignment_regime == "max_gap_all_buy_bearish_disagreement":
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
    elif p1_alignment_regime == "persistent_sell_heavy_bullish_disagreement":
        p1_summary_state = "persistent_sell_heavy_bullish_disagreement"
        p1_summary_text = "Persistent sell-heavy bullish disagreement in copy flow"
    elif p1_alignment_regime == "sell_heavy_bullish_disagreement":
        p1_summary_state = "sell_heavy_bullish_disagreement"
        p1_summary_text = "Sell-heavy bullish disagreement in copy flow"
    elif p1_alignment_regime == "persistent_soft_flat_order_bearish_disagreement":
        p1_summary_state = "persistent_soft_flat_order_bearish_disagreement"
        p1_summary_text = "Persistent soft flat-order bearish disagreement in copy flow"
    elif p1_alignment_regime == "soft_flat_order_bearish_disagreement":
        p1_summary_state = "soft_flat_order_bearish_disagreement"
        p1_summary_text = "Soft flat-order bearish disagreement in copy flow"
    elif p1_alignment_regime == "flat_order_bearish_disagreement":
        p1_summary_state = "flat_order_bearish_disagreement"
        p1_summary_text = "Flat-order bearish disagreement in copy flow"
    elif p1_alignment_regime == "bearish_crowded_expensive":
        p1_summary_state = "bearish_crowded_expensive"
        p1_summary_text = "Bearish crowded-expensive copy flow"
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

    strong_transition_regimes = {
        "anonymous_zero_spend_bearish_crowded_expensive",
        "mixed_transition_after_bearish_crowding",
        "flip_flop_extreme_copy_instability",
        "persistent_sell_heavy_bullish_disagreement",
        "persistent_soft_flat_order_bearish_disagreement",
        "bearish_crowded_expensive",
    }
    if p1_alignment_regime in strong_transition_regimes and p1_source_scan_time:
        p1_recent_strong_regime = p1_alignment_regime
        p1_recent_strong_regime_source_scan_time = p1_source_scan_time
        p1_recent_strong_regime_seen_at = now.isoformat()
        p1_recent_strong_regime_age_minutes = 0.0
    elif p1_recent_strong_regime_seen_at:
        try:
            recent_seen_dt = datetime.datetime.fromisoformat(p1_recent_strong_regime_seen_at)
            p1_recent_strong_regime_age_minutes = round((now - recent_seen_dt).total_seconds() / 60, 1)
        except Exception:
            p1_recent_strong_regime_age_minutes = None
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
    elif p1_anonymous_zero_spend_bearish_crowded_expensive:
        p1_insights.append({
            "source": "Copy Structure",
            "text": f"🧩 anonymous zero-spend bearish crowded-expensive: directional skew {p1_directional_skew:+.2f}, order-flow skew {p1_order_flow_skew:+.2f}, avg price ${p1_avg_signal_price:.3f}, total size {(sa.get('total_size', 0) or 0):.0f}"
        })
    elif p1_mixed_transition_after_bearish_crowding:
        p1_insights.append({
            "source": "Copy Structure",
            "text": f"🧩 mixed transition after bearish crowding: directional skew {p1_directional_skew:+.2f}, order-flow skew {p1_order_flow_skew:+.2f}, avg price ${p1_avg_signal_price:.3f}, total size {(sa.get('total_size', 0) or 0):.0f}"
        })
    elif p1_flip_flop_extreme_copy_instability:
        p1_insights.append({
            "source": "Copy Structure",
            "text": f"🧩 flip-flop extreme instability: directional skew {p1_directional_skew:+.2f}, order-flow skew {p1_order_flow_skew:+.2f}, avg price ${p1_avg_signal_price:.3f}"
        })
    elif p1_aligned_bearish_crowded:
        p1_insights.append({
            "source": "Copy Structure",
            "text": f"💸 aligned bearish crowding: directional skew {p1_directional_skew:+.2f}, order-flow skew {p1_order_flow_skew:+.2f}, avg price ${p1_avg_signal_price:.3f}"
        })
    if p1_recent_strong_regime and p1_recent_strong_regime != p1_alignment_regime and p1_recent_strong_regime_age_minutes is not None:
        p1_insights.append({
            "source": "Copy Transition",
            "text": f"🕘 last stronger regime {p1_recent_strong_regime} seen {p1_recent_strong_regime_age_minutes}m ago"
        })
    elif p1_recent_strong_regime and p1_recent_strong_regime == p1_alignment_regime and p1_recent_strong_regime_source_scan_time:
        p1_insights.append({
            "source": "Copy Transition",
            "text": f"🕘 stronger regime active since scan {p1_recent_strong_regime_source_scan_time}"
        })
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
    elif p1_soft_flat_order_bearish_disagreement:
        p1_insights.append({
            "source": "Copy Structure",
            "text": f"🧩 soft flat-order bearish disagreement: directional skew {p1_directional_skew:+.2f}, order-flow skew {p1_order_flow_skew:+.2f}, gap {p1_directional_gap:.2f}, avg price ${p1_avg_signal_price:.3f}"
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

# ── Alpha Research Snapshot (Pillar 4) ──
alpha_fng = alpha_signal.get("fear_greed")
alpha_fng_class = alpha_signal.get("fear_greed_class")
alpha_fng_ctx = alpha_signal.get("fear_greed_context", {}) or {}
alpha_micro = alpha_signal.get("btc_microstructure", {}) or {}
alpha_regime = alpha_signal.get("regime_state", {}) or {}
alpha_fast = alpha_signal.get("fast_regime", {}) or {}
alpha_squeeze = alpha_signal.get("funding_squeeze", {}) or {}
alpha_liq = alpha_signal.get("liquidation_signal", {}) or {}
alpha_pm_risk = alpha_signal.get("pm_risk_context", {}) or {}
alpha_btc_classifier = alpha_signal.get("btc_regime_classifier", {}) or {}
alpha_transition = alpha_signal.get("transition_context", {}) or {}
alpha_snapshot_age_minutes = None
try:
    alpha_ts = alpha_signal.get("timestamp")
    if alpha_ts:
        alpha_dt = datetime.datetime.fromisoformat(alpha_ts.replace("Z", "+00:00"))
        alpha_snapshot_age_minutes = round((now - alpha_dt).total_seconds() / 60, 1)
except:
    alpha_snapshot_age_minutes = None

alpha_signals_generated = 0
for candidate in [
    alpha_btc_classifier.get("state"),
    alpha_squeeze.get("direction"),
    alpha_liq.get("direction"),
    alpha_fng_ctx.get("regime"),
]:
    if candidate and str(candidate).lower() not in {"neutral", "none", "mixed_transition"}:
        alpha_signals_generated += 1

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

p2_hour_gate_score = {}
p2_label_collector = {}
p2_03utc_bias_comparator = {}
p2_03utc_acquisition_gap = {}
try:
    _quality_script = '/home/ubuntu/clawd/scripts/analyze_pm_outcome_quality.py'
    _outside_script = '/home/ubuntu/clawd/scripts/analyze_pm_outside_shadow.py'
    _hour_script = '/home/ubuntu/clawd/scripts/score_pm_hour_gates.py'
    _label_script = '/home/ubuntu/clawd/scripts/build_pm_smart_entry_label_collector.py'
    _bias_comparator_script = '/home/ubuntu/clawd/scripts/analyze_pm_03utc_bias_comparator.py'
    _acquisition_gap_script = '/home/ubuntu/clawd/scripts/audit_pm_03utc_acquisition_gap.py'
    for _script in [_quality_script, _outside_script, _hour_script, _label_script, _bias_comparator_script, _acquisition_gap_script]:
        if os.path.exists(_script):
            _cmd = [_script] if os.access(_script, os.X_OK) else [sys.executable, _script]
            subprocess.run(_cmd, capture_output=True, timeout=30)
    with open('/home/ubuntu/clawd/research/pm_hour_gate_score.json') as _hgf:
        p2_hour_gate_score = json.load(_hgf)
except Exception:
    p2_hour_gate_score = {}

try:
    with open('/home/ubuntu/clawd/research/pm_smart_entry_label_collector.json') as _p2_lcf:
        p2_label_collector = json.load(_p2_lcf)
except Exception:
    p2_label_collector = {}

try:
    with open('/home/ubuntu/clawd/research/pm_03utc_bias_comparator.json') as _p2_bcf:
        p2_03utc_bias_comparator = json.load(_p2_bcf)
except Exception:
    p2_03utc_bias_comparator = {}

try:
    with open('/home/ubuntu/clawd/research/pm_03utc_acquisition_gap.json') as _p2_agf:
        p2_03utc_acquisition_gap = json.load(_p2_agf)
except Exception:
    p2_03utc_acquisition_gap = {}

_p2_live_alignment = p2_hour_gate_score.get('live_alignment') or {}
_p2_extra_risk = _p2_live_alignment.get('extra_hour_risk') or {}
_p2_03_bands = p2_03utc_bias_comparator.get('bands') or {}
_p2_03_best_band = (p2_03utc_bias_comparator.get('promotion_gate') or {}).get('best_proxy_band')
p2_hour_gate_summary = {
    "recommended_active_hours": p2_hour_gate_score.get('recommended_active_hours'),
    "recommended_confirmation_only_hours": p2_hour_gate_score.get('recommended_confirmation_only_hours'),
    "live_alignment_status": _p2_live_alignment.get('status'),
    "live_extra_hours": _p2_live_alignment.get('live_extra_hours'),
    "extra_hour_risk": _p2_extra_risk,
    "live_edit_gate": p2_hour_gate_score.get('live_edit_gate'),
    "outcome_freshness": p2_hour_gate_score.get('outcome_freshness'),
    "outcome_pipeline_health": p2_hour_gate_score.get('outcome_pipeline_health'),
    "alpha_context_status": (p2_hour_gate_score.get('alpha_context_breakdown') or {}).get('status'),
    "alpha_context_rows": (p2_hour_gate_score.get('alpha_context_breakdown') or {}).get('alpha_context_rows'),
    "label_collector": {
        "decision": p2_label_collector.get("decision"),
        "totals": p2_label_collector.get("totals"),
        "promotion_gate": p2_label_collector.get("promotion_gate"),
        "shadow_03_preferred_descriptor": p2_label_collector.get("shadow_03_preferred_descriptor"),
    },
    "shadow_03_bias_comparator": {
        "decision": p2_03utc_bias_comparator.get("decision"),
        "definition_common_gate": p2_03utc_bias_comparator.get("definition_common_gate"),
        "post_retirement_realized_rows": p2_03utc_bias_comparator.get("post_retirement_realized_rows"),
        "common_gate_rows": p2_03utc_bias_comparator.get("common_gate_rows"),
        "best_proxy_band": _p2_03_best_band,
        "best_proxy_band_stats": _p2_03_bands.get(_p2_03_best_band) if _p2_03_best_band else None,
        "watch_bands": {
            "45_60": _p2_03_bands.get("45_60"),
            "45_70": _p2_03_bands.get("45_70"),
            "60_80": _p2_03_bands.get("60_80"),
        },
        "gate_health": p2_03utc_bias_comparator.get("gate_health"),
        "compact_blocker_labels": (p2_03utc_bias_comparator.get("gate_health") or {}).get("compact_blocker_labels"),
        "zero_realized_streak": (p2_03utc_bias_comparator.get("gate_health") or {}).get("zero_realized_streak"),
        "latest_gate_health_artifact": p2_03utc_bias_comparator.get("latest_gate_health_artifact"),
        "promotion_gate": p2_03utc_bias_comparator.get("promotion_gate"),
    },
    "shadow_03_acquisition_gap": {
        "decision": p2_03utc_acquisition_gap.get("decision"),
        "coverage": p2_03utc_acquisition_gap.get("coverage"),
        "blockers": p2_03utc_acquisition_gap.get("blockers"),
        "next_data_target": p2_03utc_acquisition_gap.get("next_data_target"),
    },
}

hl_directional_running = process_running("hl_trading_engine", "hl_live_trader.py")
hl_momentum_running = process_running("hl_momentum")

engine_state_health = annotate_state_owner(
    load_state_health("/home/ubuntu/clawd/hyperliquid-trader/engine_state.json"),
    "hl_trading_engine.py",
    "hl_trading_engine.py",
)
funding_arb_state_health = annotate_state_owner(
    load_state_health("/home/ubuntu/clawd/hyperliquid-trader/funding_arb_state.json"),
    "hl_funding_arb.py",
    "hl_funding_arb.py",
)
momentum_state_health = annotate_state_owner(
    load_state_health("/home/ubuntu/clawd/hyperliquid-trader/momentum_state.json"),
    "hl_momentum.py",
    "hl_momentum.py",
    "momentum_strategy.py",
)
hl_directional_log_health = load_file_mtime_health("/home/ubuntu/clawd/hyperliquid-trader/hl_trading.log")
hl_live_state_health = annotate_state_owner(
    load_state_health("/home/ubuntu/clawd/hyperliquid-trader/hl_live_state.json", stale_after_minutes=5),
    "hl_live_trader.py",
    "hl_live_trader.py",
)
hl_live_state_payload = {}
try:
    with open("/home/ubuntu/clawd/hyperliquid-trader/hl_live_state.json") as f:
        loaded_hl_live_state = json.load(f)
        if isinstance(loaded_hl_live_state, dict):
            hl_live_state_payload = loaded_hl_live_state
except Exception:
    hl_live_state_payload = {}
hl_stale_components = [
    name for name, health in [
        ("hl_live_state", hl_live_state_health),
        ("engine_state", engine_state_health),
        ("funding_arb_state", funding_arb_state_health),
        ("momentum_state", momentum_state_health),
    ] if health.get("stale", True)
]

strategies = [
    {
        "name": "PM Smart Entry",
        "status": "LIVE" if process_running("trading_bot.py") else "DOWN",
        "trades": total_trades,
        "win_rate": round(pm_win_rate, 1),
        "pnl": pm_pnl,
        "sharpe": 0.0
    },
    {
        "name": "HL Directional",
        "status": "LIVE" if hl_directional_running else "DOWN",
        "trades": len(hl_positions),
        "win_rate": 0,
        "pnl": sum(p["pnl"] for p in hl_positions),
        "sharpe": 0.0
    },
    {
        "name": "HL Funding Arb",
        "status": "SHELVED" if funding_arb_state_health.get("stale", True) else "READY",
        "trades": 0,
        "win_rate": 0,
        "pnl": 0.0,
        "sharpe": 0.0
    },
    {
        "name": "HL Momentum",
        "status": "DRY-RUN" if hl_momentum_running else ("STALE" if momentum_state_health.get("stale", True) else "OFF"),
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
# Count shipped parameter changes plus active paper/research branches.
# The original dashboard hard-coded `6 changes`, which made P3 look stale even
# while new HL strategy branches were being scored in research/*.jsonl.

p3_changes = [
    {"date": "Mar 16", "param": "min_price", "old": "none", "new": "$0.50", "reason": "Prices <$0.50 = losers"},
    {"date": "Mar 16", "param": "entry_delay", "old": "0s", "new": "60s", "reason": "First 60s = coin flip"},
    {"date": "Mar 19", "param": "kelly_fraction", "old": "0.10", "new": "0.25", "reason": "SolSt1ne: half-Kelly"},
    {"date": "Mar 19", "param": "conviction_min", "old": "2", "new": "3", "reason": "SolSt1ne: stack edges"},
    {"date": "Mar 19", "param": "divergence_threshold", "old": "0.0", "new": "0.08", "reason": "SolSt1ne: 8% AI filter"},
    {"date": "Mar 20", "param": "min_price", "old": "$0.65", "new": "$0.50", "reason": "Was blocking all trades"},
]

def _load_last_jsonl(path):
    try:
        lines = [line.strip() for line in open(path) if line.strip()]
        return json.loads(lines[-1]) if lines else {}
    except Exception:
        return {}

p3_strategy_branches = []
try:
    with open('/home/ubuntu/clawd/research/p3-momentum-episode-summary.json') as _f:
        p3_momentum_episode_summary = json.load(_f)
except Exception as _e:
    p3_momentum_episode_summary = {
        "decision": "SUMMARY_UNAVAILABLE",
        "combined_promotion_gate": {
            "pass": False,
            "blockers": ["momentum_episode_summary_unavailable"],
        },
        "load_error": str(_e),
    }
_jto = _load_last_jsonl('/home/ubuntu/clawd/research/hl_jto_momentum_score_history.jsonl')
if _jto:
    _m15 = ((_jto.get('metrics') or {}).get('15m') or {})
    p3_strategy_branches.append({
        "name": "hl_jto_strong_trend_momentum_v0_paper",
        "status": "paper_watch",
        "rows": _jto.get('rows_dedup'),
        "wr_15m": _m15.get('wr'),
        "avg_15m": _m15.get('avg_return'),
    })
_rv = _load_last_jsonl('/home/ubuntu/clawd/research/hl_range_vol_filtered_score_history.jsonl')
if _rv:
    _all = (((_rv.get('buckets') or {}).get('all') or {}).get('15m') or {})
    p3_strategy_branches.append({
        "name": "hl_range_vol_filtered_v0_paper",
        "status": "paper_low_priority",
        "rows": ((_rv.get('buckets') or {}).get('all') or {}).get('rows'),
        "wr_15m": _all.get('wr'),
        "avg_15m": _all.get('avg_return'),
    })
_md = _load_last_jsonl('/home/ubuntu/clawd/research/hl_micro_drift_score_history.jsonl')
if _md:
    _md15 = ((_md.get('metrics') or {}).get('immediate_15m') or {})
    p3_strategy_branches.append({
        "name": "hl_range_micro_drift_v0_paper",
        "status": "paper_watch",
        "rows": _md.get('rows_total') or _md.get('rows_dedup') or _md.get('n'),
        "wr_15m": _md15.get('wr'),
        "avg_15m": _md15.get('avg_return'),
    })

_hl_paper_backfill_status = {"ran": False, "rows_updated": None, "error": None}
try:
    _paper_backfill_script = '/home/ubuntu/clawd/scripts/score_hl_paper_signals.py'
    if os.path.exists(_paper_backfill_script):
        _pbf = subprocess.run([_paper_backfill_script], capture_output=True, text=True, timeout=25)
        _hl_paper_backfill_status["ran"] = True
        _hl_paper_backfill_status["returncode"] = _pbf.returncode
        _m = re.search(r'rows_updated\s+(\d+)', (_pbf.stdout or ''))
        _hl_paper_backfill_status["rows_updated"] = int(_m.group(1)) if _m else None
        if _pbf.returncode != 0:
            _hl_paper_backfill_status["error"] = (_pbf.stderr or _pbf.stdout or '')[-500:]
except Exception as _e:
    _hl_paper_backfill_status = {"ran": False, "rows_updated": None, "error": str(_e)}

_hl_canonical_paper_audit = {}
try:
    _canonical_emit_script = '/home/ubuntu/clawd/scripts/emit_hl_canonical_paper_signals.py'
    if os.path.exists(_canonical_emit_script):
        subprocess.run(['python3', _canonical_emit_script], capture_output=True, timeout=10)
    with open('/home/ubuntu/clawd/research/hl_canonical_paper_signals_audit.json') as _caf:
        _hl_canonical_paper_audit = json.load(_caf)
except Exception as _e:
    _hl_canonical_paper_audit = {"error": str(_e)}

_range_lowvol = {}
try:
    _range_lowvol_script = '/home/ubuntu/clawd/scripts/score_hl_range_lowvol_v0.py'
    if os.path.exists(_range_lowvol_script):
        subprocess.run([_range_lowvol_script], capture_output=True, timeout=10)
    with open('/home/ubuntu/clawd/research/hl_range_lowvol_v0_score.json') as _rlf:
        _range_lowvol = json.load(_rlf)
except Exception:
    _range_lowvol = {}
if _range_lowvol:
    _rl30 = ((_range_lowvol.get('metrics') or {}).get('30m') or {})
    _exception = (((_range_lowvol.get('p4_exception_test_30m') or {}).get('fast_range_lowvol_slowstop_euphoria_long_copy_disagrees')) or {})
    p3_strategy_branches.append({
        "name": "hl_range_lowvol_v0_exception_paper",
        "status": "paper_only_macro_capped",
        "rows": _range_lowvol.get('rows_total'),
        "wr_30m": _rl30.get('wr'),
        "avg_30m": _rl30.get('avg'),
        "exception_n": _exception.get('n'),
        "exception_wr_30m": _exception.get('wr'),
        "exception_avg_30m": _exception.get('avg'),
        "exception_promotion_audit": _range_lowvol.get('p4_exception_promotion_audit'),
        "p4_context": _range_lowvol.get('p4_context'),
        "source_health": _range_lowvol.get('source_health'),
        "filter_diagnostics": _range_lowvol.get('filter_diagnostics'),
        "live_ready": _range_lowvol.get('live_ready'),
        "live_block_details": _range_lowvol.get('live_block_details'),
        "block_reason": _range_lowvol.get('live_block_reason'),
    })

_local_range_trend = {}
try:
    _local_range_trend_script = '/home/ubuntu/clawd/scripts/score_hl_local_range_trend_v0.py'
    if os.path.exists(_local_range_trend_script):
        subprocess.run([_local_range_trend_script], capture_output=True, timeout=10)
    with open('/home/ubuntu/clawd/research/hl_local_range_trend_v0_score.json') as _lrtf:
        _local_range_trend = json.load(_lrtf)
except Exception:
    _local_range_trend = {}
if _local_range_trend:
    _lrt30 = ((_local_range_trend.get('metrics') or {}).get('30m') or {})
    p3_strategy_branches.append({
        "name": "hl_local_range_trend_v0_paper",
        "status": "paper_only_new_branch",
        "rows": _local_range_trend.get('rows_total'),
        "wr_15m": ((_local_range_trend.get('metrics') or {}).get('15m') or {}).get('wr'),
        "avg_15m": ((_local_range_trend.get('metrics') or {}).get('15m') or {}).get('avg'),
        "wr_30m": _lrt30.get('wr'),
        "avg_30m": _lrt30.get('avg'),
        "wr_60m": ((_local_range_trend.get('metrics') or {}).get('60m') or {}).get('wr'),
        "avg_60m": ((_local_range_trend.get('metrics') or {}).get('60m') or {}).get('avg'),
        "promotion_audit": _local_range_trend.get('promotion_audit'),
        "exit_variant_audit": _local_range_trend.get('exit_variant_audit'),
        "maturity": _local_range_trend.get('maturity'),
        "source_health": _local_range_trend.get('source_health'),
        "live_ready": _local_range_trend.get('live_ready'),
        "live_block_details": _local_range_trend.get('live_block_details'),
        "block_reason": _local_range_trend.get('live_block_reason'),
    })

_short_aligned_replay = {}
try:
    _short_aligned_replay_script = '/home/ubuntu/clawd/scripts/replay_hl_short_aligned_from_binance.py'
    if os.path.exists(_short_aligned_replay_script):
        subprocess.run(['python3', _short_aligned_replay_script], capture_output=True, timeout=20)
    with open('/home/ubuntu/clawd/research/hl_short_aligned_binance_replay.json') as _sarf:
        _short_aligned_replay = json.load(_sarf)
except Exception as _e:
    _short_aligned_replay = {"error": str(_e)}
if _short_aligned_replay:
    _sar30 = ((_short_aligned_replay.get('horizons') or {}).get('30m') or {})
    _sar_dedupe = _short_aligned_replay.get('dedupe_summary') or {}
    _sar_coin_audit = _short_aligned_replay.get('coin_filter_audit') or _sar_dedupe.get('coin_filter_audit') or {}
    _sar_eth_quality = _short_aligned_replay.get('eth_cluster_quality_audit') or _sar_dedupe.get('eth_cluster_quality_audit') or {}
    _sar_coin_buckets = _short_aligned_replay.get('coin_timestamp_bucket_audit') or _sar_dedupe.get('coin_timestamp_bucket_audit') or {}
    _sar_fresh_two_day = _short_aligned_replay.get('fresh_two_day_candidate_audit') or _sar_dedupe.get('fresh_two_day_candidate_audit') or {}
    _sar_freshness = _short_aligned_replay.get('setup_freshness_audit') or _sar_dedupe.get('setup_freshness_audit') or {}
    _sar_stagnation = _short_aligned_replay.get('candidate_stagnation_audit') or _sar_dedupe.get('candidate_stagnation_audit') or {}
    _sar_setup_trend = _short_aligned_replay.get('setup_funnel_trend_audit') or {}
    _sar_promo = _short_aligned_replay.get('promotion_audit') or {}
    _sar_deduped30 = _sar_promo.get('deduped_30m') or ((_sar_dedupe.get('deduped_horizons') or {}).get('30m') or {})
    _sar_current30 = _sar_promo.get('current_30m') or _sar30
    p3_strategy_branches.append({
        "name": "hl_short_aligned_binance_replay_bridge",
        "status": "research_only_public_candle_bridge",
        "rows": _short_aligned_replay.get('candidate_rows'),
        "wr_30m": _sar30.get('wr'),
        "avg_30m": _sar30.get('avg'),
        "latest_candidate_ts": _short_aligned_replay.get('latest_candidate_ts'),
        "setup_freshness_audit": _sar_freshness,
        "candidate_stagnation_audit": _sar_stagnation,
        "setup_funnel_trend_audit": _sar_setup_trend,
        "setup_freshness_label": _sar_freshness.get('label'),
        "unique_candidate_rows": _sar_dedupe.get('unique_candidate_rows'),
        "latest_unique_candidate_ts": _sar_dedupe.get('latest_unique_candidate_ts'),
        "deduped_30m_wr": _sar_deduped30.get('wr'),
        "deduped_30m_rxe_bp": _sar_deduped30.get('rxe_bp'),
        "current_30m_n": _sar_current30.get('n'),
        "current_30m_wr": _sar_current30.get('wr'),
        "current_30m_rxe_bp": _sar_current30.get('rxe_bp'),
        "coin_filter_audit": _sar_coin_audit,
        "eth_cluster_quality_audit": _sar_eth_quality,
        "coin_timestamp_bucket_audit": _sar_coin_buckets,
        "fresh_two_day_candidate_audit": _sar_fresh_two_day,
        "promotion_blockers": _sar_promo.get('blockers'),
        "diagnostics": _short_aligned_replay.get('diagnostics'),
        "promotion_audit": _short_aligned_replay.get('promotion_audit'),
    })

p3_short_aligned_replay_watch = {}
if _short_aligned_replay:
    _sar_dedupe = _short_aligned_replay.get('dedupe_summary') or {}
    _sar_coin_audit = _short_aligned_replay.get('coin_filter_audit') or _sar_dedupe.get('coin_filter_audit') or {}
    _sar_eth_quality = _short_aligned_replay.get('eth_cluster_quality_audit') or _sar_dedupe.get('eth_cluster_quality_audit') or {}
    _sar_coin_buckets = _short_aligned_replay.get('coin_timestamp_bucket_audit') or _sar_dedupe.get('coin_timestamp_bucket_audit') or {}
    _sar_fresh_two_day = _short_aligned_replay.get('fresh_two_day_candidate_audit') or _sar_dedupe.get('fresh_two_day_candidate_audit') or {}
    _sar_freshness = _short_aligned_replay.get('setup_freshness_audit') or _sar_dedupe.get('setup_freshness_audit') or {}
    _sar_stagnation = _short_aligned_replay.get('candidate_stagnation_audit') or _sar_dedupe.get('candidate_stagnation_audit') or {}
    _sar_setup_trend = _short_aligned_replay.get('setup_funnel_trend_audit') or {}
    _sar_promo = _short_aligned_replay.get('promotion_audit') or {}
    _sar_current30 = _sar_promo.get('current_30m') or (((_short_aligned_replay.get('horizons') or {}).get('30m')) or {})
    _sar_deduped30 = _sar_promo.get('deduped_30m') or ((_sar_dedupe.get('deduped_horizons') or {}).get('30m') or {})
    p3_short_aligned_replay_watch = {
        "state": _sar_promo.get('state') or "BLOCK_LIVE",
        "decision": _sar_promo.get('decision') or "research_only",
        "current_candidate_rows": _short_aligned_replay.get('candidate_rows'),
        "unique_candidate_rows": _sar_dedupe.get('unique_candidate_rows'),
        "unique_candidate_ledger_rows": _sar_dedupe.get('unique_candidate_ledger_rows'),
        "latest_candidate_ts": _short_aligned_replay.get('latest_candidate_ts'),
        "latest_unique_candidate_ts": _sar_dedupe.get('latest_unique_candidate_ts'),
        "setup_freshness_audit": _sar_freshness,
        "candidate_stagnation_audit": _sar_stagnation,
        "setup_funnel_trend_audit": _sar_setup_trend,
        "setup_freshness_label": _sar_freshness.get('label'),
        "current_30m": _sar_current30,
        "deduped_30m": _sar_deduped30,
        "duplicate_replay_rows_removed": _sar_dedupe.get('duplicate_replay_rows_removed'),
        "observed_candidate_rows_with_replays": _sar_dedupe.get('observed_candidate_rows_with_replays'),
        "promotion_blockers": _sar_promo.get('blockers') or [],
        "coin_filter_audit": _sar_coin_audit,
        "eth_cluster_quality_audit": _sar_eth_quality,
        "coin_timestamp_bucket_audit": _sar_coin_buckets,
        "fresh_two_day_candidate_audit": _sar_fresh_two_day,
        "thresholds": _sar_promo.get('thresholds') or {},
        "watch_counter": _short_aligned_replay.get('watch_counter') or {},
        "ledger_path": _sar_dedupe.get('unique_candidate_ledger_path') or _short_aligned_replay.get('unique_candidate_ledger_path'),
    }

_p3_paper_health = {}
try:
    _health_script = '/home/ubuntu/clawd/scripts/check_hl_paper_health.py'
    if os.path.exists(_health_script):
        subprocess.run([_health_script], capture_output=True, timeout=10)
    with open('/home/ubuntu/clawd/research/hl_paper_health.json') as _hf:
        _p3_paper_health = json.load(_hf)
except Exception:
    _p3_paper_health = {}

_p3_suppressor_labels = {}
try:
    with open('/home/ubuntu/clawd/research/hl_paper_suppressor_labels.json') as _sf:
        _p3_suppressor_labels = json.load(_sf)
except Exception:
    _p3_suppressor_labels = {}
if _p3_suppressor_labels:
    _labels = _p3_suppressor_labels.get('labels') or {}
    _trump = _labels.get('SUPPRESS_TRUMP_TREND_UP') or {}
    _ondo = _labels.get('WATCH_ONDO_REQUIRE_30M_CONFIRMATION') or {}
    _wif = _labels.get('SUPPRESS_WIF_MIXED_LOW_BREAKOUT') or {}
    p3_strategy_branches.append({
        "name": "hl_paper_suppressor_labels_v0",
        "status": _p3_suppressor_labels.get('decision') or "PAPER_ONLY_DO_NOT_CHANGE_LIVE_EXECUTION",
        "rows": _p3_suppressor_labels.get('rows_scored_15m'),
        "labels": _labels,
        "recent_labeled_rows": _p3_suppressor_labels.get('recent_since_1745') or [],
        "trump_trend_up_wr_15m": _trump.get('wr15'),
        "trump_trend_up_avg_15m": _trump.get('avg15'),
        "trump_trend_up_wr_30m": _trump.get('wr30'),
        "ondo_watch_wr_15m": _ondo.get('wr15'),
        "ondo_watch_wr_30m": _ondo.get('wr30'),
        "wif_mixed_low_breakout_wr_15m": _wif.get('wr15'),
        "block_reason": "paper-only diagnostics; no live execution changes",
    })

_p3_v2_guard = {}
try:
    with open('/home/ubuntu/clawd/research/hl_pass_filter_v2_guard.json') as _gf:
        _p3_v2_guard = json.load(_gf)
except Exception:
    _p3_v2_guard = {}
if _p3_v2_guard:
    _v2m15 = ((_p3_v2_guard.get('metrics') or {}).get('15m') or {})
    _v2_source = _p3_v2_guard.get('source') or '/home/ubuntu/clawd/hyperliquid-trader/hl_paper_signals.jsonl'
    _v2_source_age_minutes = None
    _v2_source_stale = True
    try:
        _v2_mtime = datetime.datetime.fromtimestamp(os.path.getmtime(_v2_source), tz=datetime.timezone.utc)
        _v2_source_age_minutes = round((now - _v2_mtime).total_seconds() / 60, 1)
        _v2_source_stale = _v2_source_age_minutes > 120
    except Exception:
        pass
    p3_strategy_branches.append({
        "name": "hl_pass_filter_v2_jto_strong_guard",
        "status": "BLOCK_LIVE" if not _p3_v2_guard.get('live_ready') else "ready_review",
        "rows": _p3_v2_guard.get('v2_rows_dedup'),
        "wr_15m": _v2m15.get('wr'),
        "avg_15m": _v2m15.get('avg_return'),
        "live_ready": _p3_v2_guard.get('live_ready'),
        "block_reason": _p3_v2_guard.get('reason'),
        "candidate_filter": _p3_v2_guard.get('candidate_filter'),
        "explicit_exclusions": _p3_v2_guard.get('explicit_exclusions'),
        "broad_pass_filter_is_live_quality": _p3_v2_guard.get('broad_pass_filter_is_live_quality'),
        "source_age_minutes": _v2_source_age_minutes,
        "source_stale": _v2_source_stale,
    })

params_changed = len(p3_changes) + len(p3_strategy_branches)

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

p1_copy_gate_summary = {"posture": "UNKNOWN", "blockers": ["leaderboard_state_unavailable"]}
p1_copy_relaxation_ledger = {}
p1_copy_dispersion = {}
try:
    _p1_ledger_script = '/home/ubuntu/clawd/scripts/update_p1_copy_relaxation_ledger.py'
    if os.path.exists(_p1_ledger_script):
        subprocess.run(["python3", _p1_ledger_script], capture_output=True, timeout=10)
    _p1_dispersion_script = '/home/ubuntu/clawd/scripts/score_p1_copy_dispersion.py'
    if os.path.exists(_p1_dispersion_script):
        subprocess.run(["python3", _p1_dispersion_script], capture_output=True, timeout=10)
    try:
        with open('/home/ubuntu/clawd/research/p1-copy-relaxation-latest.json') as _p1lf:
            p1_copy_relaxation_ledger = json.load(_p1lf)
    except Exception:
        p1_copy_relaxation_ledger = {}
    try:
        with open('/home/ubuntu/clawd/research/p1-copy-dispersion-latest.json') as _p1df:
            p1_copy_dispersion = json.load(_p1df)
    except Exception:
        p1_copy_dispersion = {}
    _leaderboard_state_path = '/home/ubuntu/clawd/research/leaderboard-state.json'
    _auros = '0x023a3d058020fb76cca98f01b3c48c8938a22355'
    with open(_leaderboard_state_path) as _lf:
        _leaderboard_state = json.load(_lf)
    def _coin_summary(_coin):
        _long_count = _short_count = 0
        _long_notional = _short_notional = 0.0
        for _addr, _wallet in (_leaderboard_state or {}).items():
            if str(_addr).lower() == _auros.lower():
                continue
            _pos = ((_wallet or {}).get('positions') or {}).get(_coin)
            if not _pos:
                continue
            _notional = float(_pos.get('notional') or 0)
            if _pos.get('side') == 'LONG':
                _long_count += 1; _long_notional += _notional
            elif _pos.get('side') == 'SHORT':
                _short_count += 1; _short_notional += _notional
        return {
            "long_count": _long_count,
            "short_count": _short_count,
            "long_notional": round(_long_notional, 2),
            "short_notional": round(_short_notional, 2),
            "net_notional": round(_long_notional - _short_notional, 2),
        }
    _copy_core = {c: _coin_summary(c) for c in ['BTC', 'ETH', 'SOL', 'HYPE']}
    _copy_blockers = []
    if _copy_core['BTC']['net_notional'] <= 0:
        _copy_blockers.append('btc_ex_auros_net_not_positive')
    if _copy_core['ETH']['long_count'] == 0 or _copy_core['ETH']['net_notional'] < -10000000:
        _copy_blockers.append('eth_hard_defensive')
    if _copy_core['SOL']['net_notional'] < -10000000:
        _copy_blockers.append('sol_hard_defensive')
    if _copy_core['HYPE']['net_notional'] < 0:
        _copy_blockers.append('hype_defensive')
    _relax_checks = {
        "btc_ex_auros_net_positive": _copy_core['BTC']['net_notional'] > 0,
        "sol_ex_auros_net_gt_minus_10m": _copy_core['SOL']['net_notional'] > -10000000,
        "eth_not_near_unanimous_short": not (_copy_core['ETH']['short_count'] >= 6 and _copy_core['ETH']['long_notional'] < 100000),
        "hype_ex_auros_net_nonnegative": _copy_core['HYPE']['net_notional'] >= 0,
    }
    _relaxation_gaps = {
        "btc_net_gap_to_positive": round(max(0, 0 - _copy_core['BTC']['net_notional']), 2),
        "sol_gap_to_minus_10m": round(max(0, -10000000 - _copy_core['SOL']['net_notional']), 2),
        "hype_gap_to_nonnegative": round(max(0, 0 - _copy_core['HYPE']['net_notional']), 2),
        "eth_short_notional_remaining": round(_copy_core['ETH']['short_notional'], 2),
    }
    p1_copy_gate_summary = {
        "posture": "DEFENSIVE" if _copy_blockers else "MIXED_OR_SUPPORTIVE",
        "blockers": _copy_blockers,
        "ex_auros_core": _copy_core,
        "relaxation_progress": _relax_checks,
        "relaxation_gaps": _relaxation_gaps,
        "relaxation_score": sum(1 for _ok in _relax_checks.values() if _ok),
        "requires_to_relax": ["BTC ex-Auros net > 0", "SOL ex-Auros net > -$10M", "ETH not unanimous/near-unanimous hard short"],
    }
except Exception as _e:
    p1_copy_gate_summary = {"posture": "UNKNOWN", "blockers": ["leaderboard_state_unavailable"], "error": str(_e)}

alpha_sources = [
    {"name": "HL Leaderboard Tracker", "status": "ACTIVE", "last_signal": p1_bias.upper() + " consensus"},
    {"name": "PM Leaderboard Scraper", "status": "ACTIVE", "last_signal": "Top 20 profit leaders tracked"},
    {"name": "Funding Rate Scanner", "status": "ACTIVE", "last_signal": f"{len(funding_opps)} opportunities | {alpha_squeeze.get('direction', 'NEUTRAL')}"},
    {"name": "Fear & Greed Index", "status": "ACTIVE" if alpha_fng is not None else "PLANNED", "last_signal": f"{alpha_fng} ({alpha_fng_class}) | {alpha_fng_ctx.get('regime', 'neutral')}" if alpha_fng is not None else "—"},
    {"name": "BTC Regime Classifier", "status": "ACTIVE" if alpha_btc_classifier else "BUILDING", "last_signal": f"{alpha_btc_classifier.get('state', '—')} | {alpha_btc_classifier.get('stance', '—')}"},
    {"name": "Alpha Transition Context", "status": "ACTIVE" if alpha_transition else "BUILDING", "last_signal": f"{alpha_transition.get('transition_label', '—')} | {alpha_transition.get('posture', '—')}"},
    {"name": "Liquidation Cascade Monitor", "status": "ACTIVE" if alpha_liq else "BUILDING", "last_signal": f"{alpha_liq.get('direction', 'neutral')} | adj {alpha_liq.get('pm_adjustment', 0)}"},
]

_p4_range_blocks = (_range_lowvol.get('live_block_details') or {}) if isinstance(_range_lowvol, dict) else {}
_p4_lrt_audit = (_local_range_trend.get('promotion_audit') or {}) if isinstance(_local_range_trend, dict) else {}
p4_trade_gate_summary = {
    "posture": "BLOCK_LIVE",
    "primary_reasons": [
        "pm_risk_high" if alpha_pm_risk.get('pm_risk') == 'high' else None,
        "slow_stop" if alpha_pm_risk.get('slow_pm_action') == 'STOP' else None,
        "classifier_defensive" if alpha_btc_classifier.get('stance') == 'defensive' else None,
        "euphoria_fade_cap" if alpha_fng_ctx.get('regime') == 'euphoria_fade_watch' else None,
    ],
    "fast_regime_confidence": alpha_fast.get('confidence'),
    "fast_range_high_conf_lowvol_streak": ((_range_lowvol.get('p4_context') or {}).get('fast_range_persistence') or {}).get('fast_range_high_conf_lowvol_streak') if isinstance(_range_lowvol, dict) else None,
    "range_lowvol_blockers": _p4_range_blocks.get('blockers'),
    "local_range_trend_audit": _p4_lrt_audit,
    "local_range_trend_blockers": ((_local_range_trend.get('live_block_details') or {}).get('blockers') if isinstance(_local_range_trend, dict) else None),
    "local_range_trend_preferred_horizon": ((_local_range_trend.get('live_block_details') or {}).get('preferred_horizon_watch') if isinstance(_local_range_trend, dict) else None),
    "copy_gate_posture": (p1_copy_gate_summary or {}).get('posture'),
    "copy_gate_blockers": (p1_copy_gate_summary or {}).get('blockers'),
    "transition_stability_recommendation": p4_transition_stability.get('recommendation'),
    "transition_stability_blockers": p4_transition_stability.get('blockers'),
    "transition_blocker_attribution": p4_transition_stability.get('blocker_attribution'),
    "transition_blocker_active_age": p4_transition_stability.get('blocker_active_age'),
    "transition_blocker_reset": p4_transition_stability.get('blocker_reset'),
    "transition_blocker_reset_follow_through": p4_transition_stability.get('blocker_reset_follow_through'),
    "transition_blocker_reset_event_table": p4_transition_stability.get('blocker_reset_event_table'),
    "transition_counts_48h": p4_transition_stability.get('counts_48h'),
    "transition_live_clearance_progress": p4_transition_stability.get('live_clearance_progress'),
    "transition_live_clearance_score": p4_transition_stability.get('live_clearance_score'),
    "transition_live_clearance_total": p4_transition_stability.get('live_clearance_total'),
    "transition_clearance_delta_vs_previous_snapshot": p4_transition_stability.get('clearance_delta_vs_previous_snapshot'),
    "transition_source_freshness": p4_transition_stability.get('source_freshness'),
    "expansion_cooling_required": p4_transition_stability.get('expansion_cooling_required'),
    "last_expansion_flag_ts": p4_transition_stability.get('last_expansion_flag_ts'),
    "snapshots_since_last_expansion": p4_transition_stability.get('snapshots_since_last_expansion'),
    "hours_since_last_expansion": p4_transition_stability.get('hours_since_last_expansion'),
    "expansion_resolution_bucket": p4_transition_stability.get('expansion_resolution_bucket'),
    "defensive_streak": p4_transition_stability.get('defensive_streak'),
    "range_friendly_streak": p4_transition_stability.get('range_friendly_streak'),
    "high_risk_streak": p4_transition_stability.get('high_risk_streak'),
}
p4_trade_gate_summary["primary_reasons"] = [x for x in p4_trade_gate_summary["primary_reasons"] if x]

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

hl_bot_running = hl_directional_running

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
    "hl_bot_running": hl_bot_running,
    "hl_wallet_alignment": hl_wallet_alignment,
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
        "recent_strong_regime": p1_recent_strong_regime,
        "recent_strong_regime_seen_at": p1_recent_strong_regime_seen_at,
        "recent_strong_regime_age_minutes": p1_recent_strong_regime_age_minutes,
        "recent_strong_regime_source_scan_time": p1_recent_strong_regime_source_scan_time,
        "disagreement_regime": p1_disagreement,
        "bearish_disagreement_regime": p1_bearish_disagreement,
        "all_buy_bearish_disagreement_regime": p1_all_buy_bearish_disagreement,
        "all_buy_bearish_inversion_regime": p1_all_buy_bearish_inversion,
        "max_gap_all_buy_bearish_disagreement_regime": p1_max_gap_all_buy_bearish_disagreement,
        "max_gap_all_buy_bearish_inversion_regime": p1_max_gap_all_buy_bearish_inversion,
        "weak_directional_disagreement_regime": p1_weak_directional_disagreement,
        "persistent_neutral_disagreement_regime": p1_persistent_neutral_disagreement,
        "sell_heavy_bullish_disagreement_regime": p1_sell_heavy_bullish_disagreement,
        "persistent_sell_heavy_bullish_disagreement_regime": p1_persistent_sell_heavy_bullish_disagreement,
        "soft_flat_order_bearish_disagreement_regime": p1_soft_flat_order_bearish_disagreement,
        "persistent_soft_flat_order_bearish_disagreement_regime": p1_persistent_soft_flat_order_bearish_disagreement,
        "flat_order_bearish_disagreement_regime": p1_flat_order_bearish_disagreement,
        "bearish_crowded_expensive_regime": p1_bearish_crowded_expensive,
        "anonymous_zero_spend_bearish_crowded_expensive_regime": p1_anonymous_zero_spend_bearish_crowded_expensive,
        "mixed_transition_after_bearish_crowding_regime": p1_mixed_transition_after_bearish_crowding,
        "flip_flop_extreme_copy_instability_regime": p1_flip_flop_extreme_copy_instability,
        "expensive_mixed_bearish_regime": p1_expensive_mixed_bearish,
        "aligned_bearish_crowded_regime": p1_aligned_bearish_crowded,
        "aligned_bullish_crowded_regime": p1_aligned_bullish_crowded,
        "crowded_expensive_regime": p1_crowded_expensive,
        "structure_note": p1_structure_note,
        "insights": p1_insights,
        "copy_gate_summary": p1_copy_gate_summary,
        "copy_relaxation_ledger": p1_copy_relaxation_ledger,
        "copy_dispersion": p1_copy_dispersion,
        "evolution": _pevents.get("1", []),
    },
    
    # ═══ PILLAR 2: Edge Development ═══
    "pillar2": {
        "completion": _pscores.get("p2", 55),
        "strategies": strategies,
        "edge_history": _pevents.get("2", []),
        "hour_gate_summary": p2_hour_gate_summary,
        "hour_gate_score": p2_hour_gate_score,
        "label_collector": p2_label_collector,
        "shadow_03_bias_comparator": p2_03utc_bias_comparator,
        "shadow_03_acquisition_gap": p2_03utc_acquisition_gap,
    },
    
    # ═══ PILLAR 3: Continuous Iteration ═══
    "pillar3": {
        "completion": _pscores.get("p3", 65),
        "params_changed": params_changed,
        "research_reports": research_count + reports_count,
        "heartbeats_today": 0,  # TODO: count from logs
        "changes": _pevents.get("3", []),
        "strategy_branches": p3_strategy_branches,
        "momentum_episode_summary": p3_momentum_episode_summary,
        "canonical_paper_audit": _hl_canonical_paper_audit,
        "paper_health": _p3_paper_health,
        "short_aligned_binance_replay": _short_aligned_replay,
        "short_aligned_replay_watch": p3_short_aligned_replay_watch,
        "hl_paper_backfill": _hl_paper_backfill_status,
        "paper_suppressor_labels": _p3_suppressor_labels,
        "win_rate_7d": win_rate_7d,
        "win_rate_24h": win_rate_24h,
        "avg_trade_size": avg_trade,
        "sharpe": strategies[0]["sharpe"],
        "max_drawdown": round(max_dd, 1),
        "hl_bot_running": hl_bot_running,
        "hl_exec_wallet": (hl_wallet_alignment or {}).get("configured_wallet"),
        "hl_exec_balance": (hl_wallet_alignment or {}).get("configured_balance"),
        "hl_reference_wallet": (hl_wallet_alignment or {}).get("reference_wallet"),
        "hl_reference_balance": (hl_wallet_alignment or {}).get("reference_balance"),
        "hl_wallet_misaligned": (hl_wallet_alignment or {}).get("misaligned", False),
        "hl_wallet_message": (hl_wallet_alignment or {}).get("message", ""),
        "hl_directional_owner": "hl_live_trader.py" if process_running("hl_live_trader.py") else "hl_trading_engine.py" if process_running("hl_trading_engine.py") else "none",
        "hl_directional_log": hl_directional_log_health,
        "hl_live_state": hl_live_state_health,
        "hl_live_status": hl_live_state_payload.get("status"),
        "hl_live_execution_mode": hl_live_state_payload.get("execution_mode"),
        "hl_live_wallet_blocked": hl_live_state_payload.get("wallet_blocked"),
        "hl_live_order_notional_blocked": hl_live_state_payload.get("order_notional_blocked"),
        "hl_live_balance": hl_live_state_payload.get("balance"),
        "hl_live_planned_order_notional": hl_live_state_payload.get("planned_order_notional"),
        "hl_live_min_order_notional_usd": hl_live_state_payload.get("min_order_notional_usd"),
        "hl_live_positions_count": hl_live_state_payload.get("positions_count"),
        "hl_live_signals_count": hl_live_state_payload.get("signals_count"),
        "hl_directional_surface_summary": (
            f"hl_live_trader direct state: {hl_live_state_payload.get('execution_mode') or hl_live_state_payload.get('status', 'unknown')}"
            if process_running("hl_live_trader.py") and not hl_live_state_health.get("stale", True)
            else "hl_live_trader log telemetry fresh; direct state missing/stale"
            if process_running("hl_live_trader.py") and not hl_directional_log_health.get("stale", True)
            else "hl_live_trader running but log telemetry stale"
            if process_running("hl_live_trader.py")
            else "hl_trading_engine active"
            if process_running("hl_trading_engine.py")
            else "no live directional process"
        ),
        "engine_state": engine_state_health,
        "funding_arb_state": funding_arb_state_health,
        "momentum_state": momentum_state_health,
        "stale_components": hl_stale_components,
        "state_health_summary": (
            "stale: " + ", ".join(
                f"{name} ({health.get('owner', 'unknown')}={health.get('ownership_status', 'unknown')})"
                for name, health in [
                    ("hl_live_state", hl_live_state_health),
                    ("engine_state", engine_state_health),
                    ("funding_arb_state", funding_arb_state_health),
                    ("momentum_state", momentum_state_health),
                ] if health.get("stale", True)
            ) if hl_stale_components else "all HL state files fresh"
        ),
    },
    
    # ═══ WORK LOG ═══
    "worklog": open("/home/ubuntu/clawd/WORKLOG.md").read()[:3000] if os.path.exists("/home/ubuntu/clawd/WORKLOG.md") else "",
    
    # ═══ PILLAR 4: Alpha Research Pipeline ═══
    "pillar4": {
        "completion": 45 if alpha_transition else (35 if alpha_signal else 15),
        "data_sources": sum(1 for s in alpha_sources if s["status"] == "ACTIVE"),
        "signals_generated": alpha_signals_generated,
        "research_files": len(glob.glob("/home/ubuntu/clawd/research/*.md")),
        "snapshot_age_minutes": alpha_snapshot_age_minutes,
        "btc_regime_classifier": alpha_btc_classifier,
        "transition_context": alpha_transition,
        "transition_stability": p4_transition_stability,
        "pm_risk_context": alpha_pm_risk,
        "fear_greed": {
            "value": alpha_fng,
            "classification": alpha_fng_class,
            "context": alpha_fng_ctx,
        },
        "btc_microstructure": alpha_micro,
        "regime_state": alpha_regime,
        "fast_regime": alpha_fast,
        "trade_gate_summary": p4_trade_gate_summary,
        "sources": alpha_sources,
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
