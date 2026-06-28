import fs from 'node:fs/promises';
import path from 'node:path';

const root = process.cwd();
const dashboardDir = path.join(root, 'options-dashboard');
const tradesPath = path.join(dashboardDir, 'trades.json');
const quotesPath = path.join(dashboardDir, 'quotes.json');

const toNumber = (value) => {
  if (value === null || value === undefined || value === '--' || value === 'N/A') return null;
  const n = Number(String(value).replace(/[$,]/g, ''));
  return Number.isFinite(n) ? n : null;
};

const expiryLabel = (expiry) => {
  const d = new Date(expiry + 'T00:00:00Z');
  return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', timeZone: 'UTC' });
};

const optionKey = (trade) => [trade.expiry, String(trade.optionType).toLowerCase(), Number(trade.strike)].join('|');

async function fetchJson(url) {
  const res = await fetch(url, {
    headers: {
      'Accept': 'application/json, text/plain, */*',
      'User-Agent': 'Mozilla/5.0 brainTrade-options-dashboard/1.0'
    }
  });
  if (!res.ok) throw new Error(`${res.status} ${res.statusText} for ${url}`);
  return res.json();
}

async function update() {
  const tradesData = JSON.parse(await fs.readFile(tradesPath, 'utf8'));
  const symbols = [...new Set(tradesData.trades.map((trade) => trade.symbol))];
  const output = {
    asOf: new Date().toISOString(),
    source: 'Nasdaq delayed',
    delayNotice: 'Public delayed quotes. Refresh cadence depends on GitHub Actions schedule and data provider availability.',
    quotes: {}
  };

  for (const symbol of symbols) {
    const symbolTrades = tradesData.trades.filter((trade) => trade.symbol === symbol);
    const info = await fetchJson(`https://api.nasdaq.com/api/quote/${encodeURIComponent(symbol)}/info?assetclass=stocks`);
    const last = toNumber(info?.data?.primaryData?.lastSalePrice);
    output.quotes[symbol] = {
      symbol,
      last,
      lastTrade: info?.data?.primaryData?.lastTradeTimestamp || null,
      source: 'Nasdaq delayed',
      options: {}
    };

    for (const expiry of [...new Set(symbolTrades.map((trade) => trade.expiry))]) {
      const chain = await fetchJson(`https://api.nasdaq.com/api/quote/${encodeURIComponent(symbol)}/option-chain?assetclass=stocks&fromdate=${expiry}&todate=${expiry}&limit=999`);
      const rows = chain?.data?.table?.rows || [];
      for (const trade of symbolTrades.filter((item) => item.expiry === expiry)) {
        const wantedStrike = Number(trade.strike).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
        const row = rows.find((item) => item.expiryDate === expiryLabel(expiry) && item.strike === wantedStrike);
        if (!row) continue;
        const prefix = String(trade.optionType).toLowerCase() === 'put' ? 'p' : 'c';
        output.quotes[symbol].options[optionKey(trade)] = {
          bid: toNumber(row[`${prefix}_Bid`]),
          ask: toNumber(row[`${prefix}_Ask`]),
          last: toNumber(row[`${prefix}_Last`]),
          volume: toNumber(row[`${prefix}_Volume`]),
          openInterest: toNumber(row[`${prefix}_Openinterest`]),
          source: 'Nasdaq delayed'
        };
      }
    }
  }

  await fs.writeFile(quotesPath, JSON.stringify(output, null, 2) + '\n');
  console.log(`updated ${quotesPath}`);
}

update().catch((error) => {
  console.error(error);
  process.exit(1);
});
