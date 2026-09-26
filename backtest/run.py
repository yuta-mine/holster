"""Runs the PONS and NEAR backtests and writes results/results.md and the SVG charts.

    python3 backtest/run.py
"""
import datetime as dt
import math
import json
import os

from sim import run

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'results')

# Median USD cost per liquidity transaction, measured on each chain: (mint, burn)
GAS = {
    'Ethereum': (0.30146302525059776, 0.4646116168458491),
    'L2 (Base)': (0.012584699837775036, 0.009553993888079551),
    'Robinhood Chain': (0.0966714696, 0.0966714696),
}

DATASETS = [
    dict(key='near', title='NEAR/USDC, Uniswap v3 on Ethereum (0.3%)', file='near.json',
         start=dt.datetime(2026, 8, 27, tzinfo=dt.timezone.utc), t0=0, t1=30 * 86400, width=0.05, value=1_000.0,
         pool_L=1.4293454154469753e20 * 1e-15, chains=['Ethereum', 'L2 (Base)'],
         bands=(0.03, 0.05, 0.10, 0.20)),
    dict(key='pons', title='PONS/USDG, Uniswap v4 on Robinhood Chain, 7 days (dynamic fee)', file='pons.json',
         start=dt.datetime(2026, 9, 18, 23, 30, tzinfo=dt.timezone.utc), t0=1800, t1=1800 + 7 * 86400, width=0.10,
         value=10_000.0, pool_L=4.4745225847351430e19 * 1e-12, chains=['Robinhood Chain'],
         bands=(0.03, 0.05, 0.10, 0.20)),
    dict(key='pons16', title='PONS/USDG, Uniswap v4 on Robinhood Chain, 16 days (dynamic fee)', file='pons16.json',
         start=dt.datetime(2026, 9, 9, 23, 30, tzinfo=dt.timezone.utc), t0=1800, t1=1800 + 16 * 86400, width=0.10,
         value=10_000.0, pool_L=2.54684756045483e19 * 1e-12, chains=['Robinhood Chain'],
         bands=(0.03, 0.05, 0.10, 0.20)),
    dict(key='basecat', title='BaseCat/USDC, Uniswap v4 on Base (1%)', file='basecat.json',
         start=dt.datetime(2026, 8, 26, 23, 30, tzinfo=dt.timezone.utc), t0=1800, t1=1800 + 30 * 86400, width=0.10,
         value=10_000.0, pool_L=2.5092924228310543e18 * 1e-12, chains=['L2 (Base)'],
         bands=(0.03, 0.05, 0.10, 0.20)),
    dict(key='lit', title='LIT/USDC, Uniswap v4 on Ethereum (0.35%)', file='lit.json',
         start=dt.datetime(2026, 8, 26, 23, 30, tzinfo=dt.timezone.utc), t0=1800, t1=1800 + 30 * 86400, width=0.10,
         value=10_000.0, pool_L=6.982205008493984e17 * 1e-12, chains=['Ethereum', 'L2 (Base)'],
         bands=(0.03, 0.05, 0.10, 0.20)),
    dict(key='uni', title='UNI/USDT, Uniswap v3 on Ethereum (0.3%)', file='uni.json',
         start=dt.datetime(2026, 8, 26, 23, 30, tzinfo=dt.timezone.utc), t0=1800, t1=1800 + 30 * 86400, width=0.10,
         value=10_000.0, pool_L=1.071187005217419e18 * 1e-12, chains=['Ethereum', 'L2 (Base)'],
         bands=(0.03, 0.05, 0.10, 0.20)),
]
CHART_BAND = 0.05  # Holster example shown in the charts: band ±5%, 75% deployed
CHART_DEPLOY = 0.75


def cases(bands):
    yield 'v2 (full range)', 'v2', None, 1.0
    yield 'v3 fixed, 4 ranges over the period', 'ladder', None, 1.0
    yield 'v3 re-center when out of range', 'recenter', None, 1.0
    for d in bands:
        yield f'Holster, band ±{d * 100:.0f}%', 'holster', d, 1.0
    for d in bands:
        for dep in (0.75, 0.5, 0.25):
            yield f'Holster, band ±{d * 100:.0f}%, {dep * 100:.0f}% deployed', 'holster', d, dep


def table(ds, swaps):
    lines = [f"### {ds['title']}", '',
             f"{(ds['start'] + dt.timedelta(seconds=ds['t0'])):%Y-%m-%d %H:%M} to "
             f"{(ds['start'] + dt.timedelta(seconds=ds['t1'])):%Y-%m-%d %H:%M} (UTC), "
             f"start ${ds['value']:,.0f} (half base, half quote), each side ±{ds['width'] * 100:.0f}%, TWAP of 30 one-minute "
             'candles. P&L includes fees and gas.', '']
    head = '| Case | Fees ($) | Re-centers | Side stops | Mints/Burns |'
    sep = '|---|---:|---:|---:|---:|'
    for c in ds['chains']:
        head += f' P&L, {c} gas |'
        sep += '---:|'
    lines += [head, sep]
    for label, mode, d, dep in cases(ds['bands']):
        res = [run(swaps, ds['t0'], ds['t1'], mode, ds['width'], band=(d, d) if d else None, deploy=dep,
                   value=ds['value'], pool_L=ds['pool_L'], gas=GAS[c]) for c in ds['chains']]
        r = res[0]
        cells = ' | '.join(f"{x['pnl'] / ds['value'] * 100:+.1f}%" for x in res)
        lines.append(f"| {label} | {r['fees']:,.0f} | {r['recenters']} | {r['stops']} | {r['mints']}/{r['burns']} | {cells} |")
    return '\n'.join(lines) + '\n'


# ---------------------------------------------------------------------------------------------------------- charts

INK, MUTED, GRID, SURFACE = '#1f2328', '#656d76', '#eaeef2', '#ffffff'
COLORS = {'Holster': '#0969da', 'Re-center': '#bc4c00', 'Fixed, 4 ranges': '#8250df'}
FONT = "font-family=\"-apple-system,'Segoe UI',Helvetica,Arial,sans-serif\""


def _frame(W, H, title):
    return [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" {FONT} role="img" '
            f'aria-label="{title}">',
            f'<rect x="0.5" y="0.5" width="{W - 1}" height="{H - 1}" rx="10" fill="{SURFACE}" stroke="#d0d7de"/>',
            f'<text x="20" y="28" font-size="14" font-weight="600" fill="{INK}">{title}</text>']


def _axes(o, x, y, ymin, ymax, yfmt, L, R, T, B, W, H, days, start):
    raw = (ymax - ymin) / 5
    mag = 10 ** math.floor(math.log10(raw))
    step = next(m * mag for m in (1, 2, 2.5, 5, 10) if m * mag >= raw)
    v0 = math.ceil(ymin / step) * step
    for i in range(int((ymax - v0) / step) + 1):
        v = v0 + i * step
        o.append(f'<line x1="{L}" x2="{W - R}" y1="{y(v):.1f}" y2="{y(v):.1f}" stroke="{GRID}"/>')
        o.append(f'<text x="{L - 8}" y="{y(v) + 4:.1f}" font-size="11" fill="{MUTED}" text-anchor="end">{yfmt(v)}</text>')
    step = 5 if days > 10 else 1
    for d in range(0, int(days) + 1, step):
        o.append(f'<text x="{x(d * 86400):.1f}" y="{H - B + 18}" font-size="11" fill="{MUTED}" text-anchor="middle">'
                 f'{(start + dt.timedelta(days=d)):%m/%d}</text>')


def _days(ds):
    return f"{(ds['t1'] - ds['t0']) // 86400} days"


def price_chart(ds, holster):
    W, H, L, R, T, B = 900, 360, 64, 24, 48, 36
    s = holster['series']
    t0, t1 = ds['t0'], ds['t1']
    prices = [p['price'] for p in s]
    ymin, ymax = min(prices) * 0.97, max(prices) * 1.03
    x = lambda t: L + (t - t0) / (t1 - t0) * (W - L - R)
    y = lambda v: T + (ymax - v) / (ymax - ymin) * (H - T - B)
    o = _frame(W, H, f"{ds['title'].split(',')[0]} ({_days(ds)}): price, 30-minute TWAP and the ±{CHART_BAND * 100:.0f}% band")
    # periods when a side was stopped
    state, since = (True, True), t0
    spans = []
    for t, bid, ask in holster['events'] + [(t1, True, True)]:
        if state != (True, True):
            spans.append((since, t, state))
        state, since = (bid, ask), t
    for a, b, (bid, ask) in spans:
        w = max(x(b) - x(a), 1.2)
        color = '#cf222e' if not bid else '#1a7f37'
        o.append(f'<rect x="{x(a):.1f}" y="{T}" width="{w:.1f}" height="{H - T - B}" fill="{color}" fill-opacity="0.18"/>')
    _axes(o, x, y, ymin, ymax, lambda v: f'{v:.2f}', L, R, T, B, W, H,
          (t1 - t0) / 86400, ds['start'] + dt.timedelta(seconds=t0))
    tw = [(p['t'], p['twap']) for p in s if p['twap']]
    up = ' '.join(f"{x(t):.1f},{y(v * (1 + CHART_BAND)):.1f}" for t, v in tw)
    lo = ' '.join(f"{x(t):.1f},{y(v * (1 - CHART_BAND)):.1f}" for t, v in reversed(tw))
    o.append(f'<polygon points="{up} {lo}" fill="#0969da" fill-opacity="0.12"/>')
    o.append('<polyline points="' + ' '.join(f"{x(p['t']):.1f},{y(p['price']):.1f}" for p in s) +
             f'" fill="none" stroke="{INK}" stroke-width="1.2"/>')
    lx = L + 12
    o.append(f'<rect x="{lx}" y="{T + 8}" width="12" height="10" fill="#0969da" fill-opacity="0.25"/>'
             f'<text x="{lx + 18}" y="{T + 17}" font-size="11" fill="{INK}">TWAP ±{CHART_BAND * 100:.0f}%</text>')
    o.append(f'<rect x="{lx + 110}" y="{T + 8}" width="12" height="10" fill="#cf222e" fill-opacity="0.3"/>'
             f'<text x="{lx + 128}" y="{T + 17}" font-size="11" fill="{INK}">bid stopped</text>')
    o.append(f'<rect x="{lx + 210}" y="{T + 8}" width="12" height="10" fill="#1a7f37" fill-opacity="0.3"/>'
             f'<text x="{lx + 228}" y="{T + 17}" font-size="11" fill="{INK}">ask stopped</text>')
    o.append('</svg>')
    return '\n'.join(o)


def pnl_chart(ds, lines):
    W, H, L, R, T, B = 900, 360, 64, 150, 48, 36
    t0, t1 = ds['t0'], ds['t1']
    vals = [v for _, s in lines for _, v in s]
    ymin, ymax = min(vals + [0]), max(vals + [0])
    pad = (ymax - ymin) * 0.08
    ymin, ymax = ymin - pad, ymax + pad
    x = lambda t: L + (t - t0) / (t1 - t0) * (W - L - R)
    y = lambda v: T + (ymax - v) / (ymax - ymin) * (H - T - B)
    o = _frame(W, H, f"{ds['title'].split(',')[0]} ({_days(ds)}): P&amp;L incl. fees and gas ({ds['chains'][0]}); "
                     f"Holster = band ±{CHART_BAND * 100:.0f}%, {CHART_DEPLOY * 100:.0f}% deployed")
    _axes(o, x, y, ymin, ymax, lambda v: f'{v:+.0f}%', L, R, T, B, W, H, (t1 - t0) / 86400,
          ds['start'] + dt.timedelta(seconds=t0))
    o.append(f'<line x1="{L}" x2="{W - R}" y1="{y(0):.1f}" y2="{y(0):.1f}" stroke="{MUTED}" stroke-width="1"/>')
    for name, s in lines:
        dash = ''
        width = 2.4 if name == 'Holster' else 1.6
        o.append('<polyline points="' + ' '.join(f'{x(t):.1f},{y(v):.1f}' for t, v in s) +
                 f'" fill="none" stroke="{COLORS[name]}" stroke-width="{width}"{dash}/>')
    ends = sorted(((s[-1][1], name) for name, s in lines), reverse=True)
    last_y = -1e9
    for v, name in ends:
        yy = max(y(v) + 4, last_y + 14)
        last_y = yy
        o.append(f'<text x="{W - R + 8}" y="{yy:.1f}" font-size="12" fill="{INK}">'
                 f'<tspan fill="{COLORS[name]}">■</tspan> {name} {v:+.1f}%</text>')
    o.append('</svg>')
    return '\n'.join(o)


def main():
    os.makedirs(OUT, exist_ok=True)
    md = ['# Backtest results', '', 'Generated by `python3 backtest/run.py`. Method: [docs/backtest.md](../../docs/backtest.md).', '']
    for ds in DATASETS:
        swaps = json.load(open(os.path.join(HERE, 'data', ds['file'])))
        md.append(table(ds, swaps))
        common = dict(value=ds['value'], pool_L=ds['pool_L'], gas=GAS[ds['chains'][0]], sample_every=900)
        hol = run(swaps, ds['t0'], ds['t1'], 'holster', ds['width'], band=(CHART_BAND, CHART_BAND), deploy=CHART_DEPLOY,
                  **common)
        rec = run(swaps, ds['t0'], ds['t1'], 'recenter', ds['width'], **common)
        fix = run(swaps, ds['t0'], ds['t1'], 'ladder', ds['width'], **common)
        pct = lambda s, k: [(p['t'], p[k] / ds['value'] * 100) for p in s]
        lines = [('Holster', pct(hol['series'], 'pnl')), ('Re-center', pct(rec['series'], 'pnl')),
                 ('Fixed, 4 ranges', pct(fix['series'], 'pnl'))]
        with open(os.path.join(OUT, f"{ds['key']}-price.svg"), 'w') as f:
            f.write(price_chart(ds, hol))
        with open(os.path.join(OUT, f"{ds['key']}-pnl.svg"), 'w') as f:
            f.write(pnl_chart(ds, lines))
    with open(os.path.join(OUT, 'results.md'), 'w') as f:
        f.write('\n'.join(md))
    print('\n'.join(md))


if __name__ == '__main__':
    main()
