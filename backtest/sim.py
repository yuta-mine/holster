"""Swap-level backtest of an LP with concentrated-liquidity math.

Prices are quote per base. The LP holds idle tokens plus up to two single-sided ranges, like the contracts:
  bid range [lo, center]  funded with quote
  ask range [center, hi]  funded with base
The price path is taken from real swaps and is assumed not to change because of this LP.

Strategies
  v2        full range, placed once
  fixed     center ±W, placed once
  ladder    the period's lowest-to-highest price split into K ranges (equal in log price), placed once and never moved.
            Ranges above the start price are funded with base, ranges below with quote, each token split evenly;
            the range around the start price is split at the start price into a quote part and a base part
  recenter  center ±W, re-placed around the current price when the price leaves the range
  holster   recenter + TWAP band: a side is stopped when the price is too far from the TWAP; on every band change
            (a side stops or returns) both ranges are pulled and the allowed sides are placed next to the price
  holster with deploy < 1: the same, but each side gets at most `deploy` × half of the LP value; the rest
            stays idle
"""
import math


class Range:
    def __init__(self, lo, hi, L):
        self.lo, self.hi, self.L = lo, hi, L

    def holdings(self, p):
        a, b, s = math.sqrt(self.lo), math.sqrt(self.hi), math.sqrt(min(max(p, self.lo), self.hi))
        return self.L * (1 / s - 1 / b), self.L * (s - a)  # (base, quote)


def range_from_quote(q, lo, hi):
    return Range(lo, hi, q / (math.sqrt(hi) - math.sqrt(lo))) if q > 0 and hi > lo else None


def range_from_base(x, lo, hi):
    return Range(lo, hi, x / (1 / math.sqrt(lo) - 1 / math.sqrt(hi))) if x > 0 and hi > lo else None


class Band:
    """TWAP = average close of the last `candles` finished 1-minute candles (gaps carry the last price)."""

    def __init__(self, upper, lower, candles=30):
        self.upper, self.lower, self.n = upper, lower, candles
        self.closes, self.minute, self.last = [], None, None

    def update(self, t, p):
        m = t // 60
        if self.minute is None:
            self.minute = m
        while m > self.minute:
            self.closes.append(self.last)
            self.minute += 1
        self.closes = self.closes[-self.n:]
        self.last = p

    def twap(self):
        return sum(self.closes) / self.n if len(self.closes) >= self.n else None

    def sides(self, p):
        tw = self.twap()
        if tw is None:
            return None
        return {'bid': p <= tw * (1 + self.upper), 'ask': p >= tw * (1 - self.lower)}


class LP:
    def __init__(self, mode, p0, width, value, deploy=1.0, pool_L=None, ladder=None):
        self.mode, self.W, self.deploy, self.pool_L, self.ladder = mode, width, deploy, pool_L, ladder
        self.width_fn = None  # optional: returns the width to use at each placement (volatility-based width)
        self.base, self.quote = value / 2 / p0, value / 2
        self.ranges = {}
        self.fees = 0.0
        self.fee = 0.0
        self.mints = self.burns = self.recenters = self.stops = 0
        self.allowed = {'bid': True, 'ask': True}
        self.place_all(p0)

    def pull_all(self, p):
        for side in list(self.ranges):
            x, y = self.ranges.pop(side).holdings(p)
            self.base += x
            self.quote += y
            self.burns += 1

    def place_ladder(self, p):
        lo, hi, k = self.ladder
        edges = [lo * (hi / lo) ** (i / k) for i in range(k + 1)]
        below = [(a, min(b, p)) for a, b in zip(edges, edges[1:]) if a < p]
        above = [(max(a, p), b) for a, b in zip(edges, edges[1:]) if b > p]
        for i, (a, b) in enumerate(below):
            r = range_from_quote(self.quote / (len(below) - i), a, b)
            if r:
                self.quote -= self.quote / (len(below) - i)
                self.ranges[('bid', i)] = r
                self.mints += 1
        for i, (a, b) in enumerate(above):
            r = range_from_base(self.base / (len(above) - i), a, b)
            if r:
                self.base -= self.base / (len(above) - i)
                self.ranges[('ask', i)] = r
                self.mints += 1

    def place_all(self, p):
        """Center on p and fund each allowed side from the tokens already held (no rebalancing swap)."""
        if self.mode == 'ladder':
            return self.place_ladder(p)
        if self.width_fn:
            self.W = self.width_fn()
        self.center = p
        value = self.base * p + self.quote
        for side in ('bid', 'ask'):
            if not self.allowed[side]:
                continue
            if self.mode == 'v2':
                lo, hi = (1e-12, p) if side == 'bid' else (p, 1e12)
            else:
                lo, hi = (p * (1 - self.W), p) if side == 'bid' else (p, p * (1 + self.W))
            if side == 'bid':
                amt = self.quote if self.deploy >= 1 else min(self.quote, self.deploy * value / 2)
                r = range_from_quote(amt, lo, hi)
                if r:
                    self.quote -= amt
            else:
                amt = self.base if self.deploy >= 1 else min(self.base, self.deploy * value / 2 / p)
                r = range_from_base(amt, lo, hi)
                if r:
                    self.base -= amt
            if r:
                self.ranges[side] = r
                self.mints += 1

    def on_swap(self, p0, p1, sides):
        # 1. before the swap: band check (holster only)
        if self.mode == 'holster' and sides is not None and sides != self.allowed:
            self.stops += sum(1 for s in ('bid', 'ask') if self.allowed[s] and not sides[s])
            self.pull_all(p0)
            self.allowed = dict(sides)
            self.place_all(p0)
        # 2. the swap moves the price p0 -> p1 through the LP's ranges
        for r in self.ranges.values():
            x0, y0 = r.holdings(p0)
            x1, y1 = r.holdings(p1)
            # fees on the token received; the pool's own liquidity takes its share
            share = self.pool_L / (self.pool_L + r.L) if self.pool_L else 1.0
            if p1 < p0 and x1 > x0:
                self.fees += (x1 - x0) * self.fee / (1 - self.fee) * p1 * share
            if p1 > p0 and y1 > y0:
                self.fees += (y1 - y0) * self.fee / (1 - self.fee) * share
        # 3. re-center when the price has left the range
        if self.mode in ('recenter', 'holster'):
            if p1 < self.center * (1 - self.W) or p1 > self.center * (1 + self.W):
                self.pull_all(p1)
                self.recenters += 1
                self.place_all(p1)

    def value(self, p):
        v = self.base * p + self.quote
        for r in self.ranges.values():
            x, y = r.holdings(p)
            v += x * p + y
        return v


def run(swaps, t_start, t_end, mode, width, band=None, candles=30, deploy=1.0, value=10_000.0, pool_L=None,
        gas=(0.0, 0.0), sample_every=None, ranges=4, vol_k=None, vol_min=0.03, vol_max=0.30, vol_source='hourly'):
    """swaps: [(t_seconds, price, fee_pips)]. band: (upper, lower) as fractions, for mode 'holster'.
    vol_k: if set, the width at each placement is vol_k × daily volatility, clamped to [vol_min, vol_max].
    vol_source: 'hourly' = last 24 hourly closes; 'twap' = the TWAP's 1-minute closes. `width` is used until enough
    closes exist.
    gas: (mint, burn) cost in quote. Returns a dict of results; with `sample_every` also a P&L time series."""
    b = Band(band[0], band[1], candles) if band else None
    lp, p_prev, hodl, series, events, next_sample = None, None, None, [], [], t_start
    hourly, hour, last_p = [], None, None

    def vol_width():
        closes, per_day = (hourly[-25:], 24) if vol_source == 'hourly' else ((b.closes if b else [])[-candles:], 1440)
        if len(closes) < (25 if vol_source == 'hourly' else candles):
            return width
        r = [math.log(y / x) for x, y in zip(closes, closes[1:])]
        m = sum(r) / len(r)
        sd = math.sqrt(sum((x - m) ** 2 for x in r) / len(r)) * math.sqrt(per_day)
        return min(max(vol_k * sd, vol_min), vol_max)

    for t, p, f in swaps:
        h = t // 3600
        if hour is None:
            hour = h
        while h > hour:
            hourly.append(last_p)
            hour += 1
        hourly = hourly[-25:]
        last_p = p
        if b:
            b.update(t, p)
        if t < t_start:
            p_prev = p
            continue
        if t >= t_end:
            break
        if p_prev is None:  # first swap of the data: use it as the opening price
            p_prev = p
            continue
        if lp is None:
            ladder = None
            if mode == 'ladder':  # uses the period's price range, known only afterwards
                window = [q for tt, q, _ in swaps if t_start <= tt < t_end] + [p_prev]
                ladder = (min(window) * 0.999, max(window) * 1.001, ranges)
            lp = LP(mode, p_prev, vol_width() if vol_k else width, value, deploy, pool_L, ladder)
            if vol_k:
                lp.width_fn = vol_width
            hodl = (value / 2 / p_prev, value / 2)
        lp.fee = f / 1e6  # per-swap fee (dynamic-fee pools change it swap by swap)
        before = dict(lp.allowed)
        lp.on_swap(p_prev, p, b.sides(p_prev) if (b and mode == 'holster') else None)
        if lp.allowed != before:
            events.append((t, lp.allowed['bid'], lp.allowed['ask']))
        p_prev = p
        if sample_every and t >= next_sample:
            series.append(dict(t=t, pnl=_pnl(lp, p, gas, value), hodl=hodl[0] * p + hodl[1] - value, price=p,
                                twap=b.twap() if b else None, bid=lp.allowed['bid'], ask=lp.allowed['ask']))
            next_sample = t + sample_every
    if mode in ('v2', 'fixed'):
        lp.mints, lp.burns = 1, 0  # one position, placed once
    if sample_every:
        series.append(dict(t=t_end, pnl=_pnl(lp, p_prev, gas, value), hodl=hodl[0] * p_prev + hodl[1] - value,
                           price=p_prev, twap=b.twap() if b else None, bid=lp.allowed['bid'],
                           ask=lp.allowed['ask']))
    return dict(pnl=_pnl(lp, p_prev, gas, value), fees=lp.fees, gas=_gas(lp, gas), mints=lp.mints,
                burns=lp.burns, recenters=lp.recenters, stops=lp.stops, hodl=hodl[0] * p_prev + hodl[1] - value,
                series=series, events=events)


def _gas(lp, gas):
    return lp.mints * gas[0] + lp.burns * gas[1]


def _pnl(lp, p, gas, value):
    return lp.value(p) + lp.fees - _gas(lp, gas) - value
