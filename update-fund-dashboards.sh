#!/bin/bash
# Update BTC analysis on fund1-dashboard and mcfund-dashboard
# Runs daily via cron at 08:00 UTC

python3 << 'PYEOF'
import requests, json, datetime, re, os

# ── Fetch BTC Market Data ──────────────────────────────────────
klines = requests.get("https://api.binance.com/api/v3/klines", params={
    "symbol": "BTCUSDT", "interval": "1d", "limit": 14
}, timeout=10).json()

ticker = requests.get("https://api.binance.com/api/v3/ticker/24hr", params={
    "symbol": "BTCUSDT"
}, timeout=10).json()

price = float(ticker['lastPrice'])
change_pct = float(ticker['priceChangePercent'])
volume = float(ticker['volume'])
high = float(ticker['highPrice'])
low = float(ticker['lowPrice'])
prev_close = float(klines[-2][4])
prev_vol = float(klines[-2][5])
vol_change = ((volume / prev_vol) - 1) * 100 if prev_vol > 0 else 0

# Green/red day streak
streak = 0
streak_dir = None
for k in reversed(klines[:-1]):
    green = float(k[4]) >= float(k[1])
    if streak_dir is None:
        streak_dir = green
    if green == streak_dir:
        streak += 1
    else:
        break

# RSI 14
closes = [float(k[4]) for k in klines]
changes = [closes[i]-closes[i-1] for i in range(1, len(closes))]
if len(changes) >= 14:
    ag = sum(max(0,c) for c in changes[-14:]) / 14
    al = sum(max(0,-c) for c in changes[-14:]) / 14
    rsi = 100 - (100 / (1 + ag/al)) if al > 0 else 100
else:
    rsi = 50

# Fear & Greed
try:
    fg = requests.get("https://api.alternative.me/fng/", timeout=5).json()
    fear_greed = int(fg['data'][0]['value'])
    fg_label = fg['data'][0]['value_classification']
except:
    fear_greed = 0; fg_label = "Unknown"

# Funding rate
try:
    funding = requests.get("https://fapi.binance.com/fapi/v1/fundingRate", params={
        "symbol": "BTCUSDT", "limit": 1
    }, timeout=5).json()
    funding_rate = float(funding[0]['fundingRate']) * 100
except:
    funding_rate = 0

# Support/resistance from recent candles
recent_lows = sorted([float(k[3]) for k in klines[-7:]])
recent_highs = sorted([float(k[2]) for k in klines[-7:]])
support = recent_lows[0]
resistance = recent_highs[-1]
mcap_t = price * 19.8e6 / 1e12

# ── Generate Analysis ──────────────────────────────────────────
now = datetime.datetime.now(datetime.timezone.utc)
date_str = now.strftime("%b %d, %Y · %-I:%M %p UTC")

# Determine bias
if change_pct > 2 and rsi > 55:
    bias = "BULLISH"
    bias_class = "bias-bullish"
    emoji = "🟢"
elif change_pct < -2 and rsi < 45:
    bias = "BEARISH"
    bias_class = "bias-bearish"
    emoji = "🔴"
else:
    bias = "NEUTRAL"
    bias_class = "bias-neutral"
    emoji = "⚪"

# Build headline
parts = []
if abs(change_pct) > 1:
    parts.append(f"{'UP' if change_pct > 0 else 'DOWN'} {abs(change_pct):.1f}%")
if streak >= 2:
    parts.append(f"{streak} {'GREEN' if streak_dir else 'RED'} DAYS")
if abs(vol_change) > 30:
    parts.append(f"VOLUME {'SURGING' if vol_change > 0 else 'FADING'} {abs(vol_change):.0f}%")
if fear_greed <= 25:
    parts.append(f"EXTREME FEAR ({fear_greed})")
elif fear_greed >= 75:
    parts.append(f"EXTREME GREED ({fear_greed})")
headline = " — " + ", ".join(parts) if parts else ""

# Build analysis text
analysis_parts = []
analysis_parts.append(f"BTC at ${price:,.0f} ({change_pct:+.2f}%) — 24h range ${low:,.0f}–${high:,.0f}.")

if streak >= 2:
    analysis_parts.append(f"<strong>{streak} consecutive {'green' if streak_dir else 'red'} daily candles</strong> — {'momentum building' if streak_dir else 'selling pressure persistent'}.")

vol_desc = "elevated" if vol_change > 20 else "declining" if vol_change < -20 else "stable"
analysis_parts.append(f"Volume {vol_desc} ({vol_change:+.0f}% vs yesterday) — {'confirming the move' if abs(vol_change) > 20 else 'no strong conviction either way'}.")

analysis_parts.append(f"<strong>Funding rate {funding_rate:+.4f}%</strong> — {'shorts paying longs' if funding_rate < 0 else 'longs paying shorts' if funding_rate > 0 else 'neutral'}.")

analysis_parts.append(f"<strong>Fear & Greed at {fear_greed}</strong> ({fg_label}) — {'contrarian buy signal territory' if fear_greed < 25 else 'caution warranted' if fear_greed > 70 else 'mixed sentiment'}.")

analysis_parts.append(f"Market cap ${mcap_t:.2f}T. RSI(14) at {rsi:.0f} — {'overbought' if rsi > 70 else 'oversold' if rsi < 30 else 'neutral range'}.")

analysis_text = " ".join(analysis_parts)

# Key levels text
levels_text = f"<strong>Support:</strong> ${support:,.0f} (recent swing low) · <strong>Resistance:</strong> ${resistance:,.0f} (recent swing high) · <strong>24h range:</strong> ${low:,.0f}–${high:,.0f}"

# ── Update HTML Files ──────────────────────────────────────────
def update_dashboard(filepath):
    with open(filepath, 'r') as f:
        html = f.read()
    
    # Update date
    html = re.sub(
        r'(<div class="analysis-date" id="analysis-date">).*?(</div>)',
        f'\\1{date_str}\\2', html
    )
    
    # Update price
    html = re.sub(
        r'(<div class="analysis-price" id="analysis-price">).*?(</div>)',
        f'\\1${price:,.0f}\\2', html
    )
    
    # Update bias line
    html = re.sub(
        r'<div class="analysis-bias[^"]*">[^<]*</div>',
        f'<div class="analysis-bias {bias_class}">{emoji} {bias}{headline}</div>',
        html
    )
    
    # Update "The Setup" analysis text
    html = re.sub(
        r'(<div class="analysis-section-title">The Setup</div>\s*<div class="analysis-text">).*?(</div>)',
        f'\\1{analysis_text}\\2',
        html, flags=re.DOTALL
    )
    
    # Update key levels if present
    html = re.sub(
        r'(<div class="analysis-section-title">Key Levels</div>\s*<div class="analysis-text">).*?(</div>)',
        f'\\1{levels_text}\\2',
        html, flags=re.DOTALL
    )
    
    with open(filepath, 'w') as f:
        f.write(html)
    
    print(f"Updated: {filepath}")

FUND1 = "/home/ubuntu/clawd/agents/polymarket/fund1-dashboard/index.html"
MCFUND = "/home/ubuntu/clawd/agents/polymarket/mcfund-dashboard/index.html"

update_dashboard(FUND1)
update_dashboard(MCFUND)

print(f"BTC ${price:,.0f} ({change_pct:+.1f}%) | Bias: {bias} | F&G: {fear_greed} | RSI: {rsi:.0f}")
PYEOF

# Push to GitHub
cd /home/ubuntu/clawd/agents/polymarket/fund1-dashboard
git add -A && git commit -m "Daily BTC analysis $(date -u +%Y-%m-%d)" && git push origin main 2>/dev/null

cd /home/ubuntu/clawd/agents/polymarket/mcfund-dashboard
git add -A && git commit -m "Daily BTC analysis $(date -u +%Y-%m-%d)" && git push origin main 2>/dev/null

echo "Done — dashboards updated and pushed"
