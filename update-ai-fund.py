#!/usr/bin/env python3
"""Update AI Fund active trade prices in data.json"""
import json, requests

data_file = '/home/ubuntu/clawd/dashboard/data.json'

with open(data_file) as f:
    d = json.load(f)

if 'ai_fund' not in d or not d['ai_fund'].get('active_trades'):
    exit()

for trade in d['ai_fund']['active_trades']:
    asset = trade['asset']
    try:
        r = requests.get(f"https://api.binance.com/api/v3/ticker/price?symbol={asset}USDT", timeout=5)
        price = float(r.json()['price'])
        trade['current_price'] = round(price, 2)
        
        size = trade['size']
        entry = trade['entry_price']
        direction = trade['direction']
        
        if direction == 'LONG':
            trade['unrealized_pnl'] = round((price - entry) * size, 2)
        else:
            trade['unrealized_pnl'] = round((entry - price) * size, 2)
    except Exception as e:
        print(f"Error updating {asset}: {e}")

with open(data_file, 'w') as f:
    json.dump(d, f, indent=2)
