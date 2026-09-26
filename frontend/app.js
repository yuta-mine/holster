import {
  createPublicClient, createWalletClient, custom, http, formatUnits, parseUnits, maxUint256, defineChain, decodeAbiParameters,
  encodeAbiParameters, keccak256, parseAbiItem,
} from "https://esm.sh/viem@2.21.55";
// Loaded fresh on every visit: the addresses change whenever the demo is set up again (init-demo.sh).
const { NETWORKS, DEFAULT_CHAIN_ID } = await import(`./config.js?v=${Date.now()}`);

// ---------------------------------------------------------------- ABIs
const fn = (name, inputs, outputs, stateMutability = "view") => ({
  type: "function", name, stateMutability,
  inputs: inputs.map((type) => (typeof type === "string" ? { type } : type)),
  outputs: outputs.map((type) => (typeof type === "string" ? { type } : type)),
});
const hookAbi = [
  fn("bandState", [], ["bool", "bool", "uint256", "uint256"]),
  fn("bidOn", [], ["bool"]), fn("askOn", [], ["bool"]),
  fn("bid", [], ["int24", "int24", "uint128"]), fn("ask", [], ["int24", "int24", "uint128"]),
  fn("widthBps", [], ["uint256"]), fn("upperBps", [], ["uint256"]), fn("lowerBps", [], ["uint256"]),
  fn("deployBps", [], ["uint256"]), fn("owner", [], ["address"]), fn("currentPrice", [], ["uint256"]),
  fn("poolKey", [], ["address", "address", "uint24", "int24", "address"]),
  fn("deposit", ["uint256", "uint256"], [], "nonpayable"), fn("withdraw", [], [], "nonpayable"),
  fn("setWidth", ["uint256"], [], "nonpayable"),
];
const tokenAbi = [
  fn("balanceOf", ["address"], ["uint256"]), fn("allowance", ["address", "address"], ["uint256"]),
  fn("approve", ["address", "uint256"], ["bool"], "nonpayable"), fn("mint", ["address", "uint256"], [], "nonpayable"),
];
const poolKeyType = { type: "tuple", components: [
  { type: "address", name: "currency0" }, { type: "address", name: "currency1" }, { type: "uint24", name: "fee" },
  { type: "int24", name: "tickSpacing" }, { type: "address", name: "hooks" }] };
const v4RouterAbi = [fn("swap", [poolKeyType, "bool", "int256", "uint160"], ["int256"], "nonpayable")];
const orderType = { type: "tuple", components: [{ type: "address", name: "maker" }, { type: "uint256", name: "traits" }, { type: "bytes", name: "data" }] };
const swapVmAbi = [
  fn("quote", [orderType, "address", "address", "uint256", "bytes"], ["uint256", "uint256", "bytes32"]),
  fn("swap", [orderType, "address", "address", "uint256", "bytes"], ["uint256", "uint256", "bytes32"], "nonpayable"),
];
const aquaStateType = { type: "tuple", components: [
  { type: "uint160", name: "sqrtPriceX96" }, { type: "uint160", name: "sqrtCenterX96" }, { type: "uint160", name: "sqrtLowerX96" },
  { type: "uint160", name: "sqrtUpperX96" }, { type: "uint128", name: "bidLiquidity" }, { type: "uint128", name: "askLiquidity" },
  { type: "bool", name: "bidOn" }, { type: "bool", name: "askOn" }, { type: "bool", name: "live" },
  { type: "address", name: "maker" }, { type: "uint16", name: "widthBps" }] };
const holsterAquaAbi = [
  fn("state", ["bytes32"], [aquaStateType]), fn("twap", ["bytes32"], ["uint256"]),
  fn("setWidth", ["bytes32", "uint16"], [], "nonpayable"),
];
const aquaAbi = [fn("safeBalances", ["address", "address", "bytes32", "address", "address"], ["uint256", "uint256"])];
// SwapVM taker data with no hooks or callbacks: 20 bytes of slice indexes + 2 bytes of flags
// (exact-in 0x01 | first transfer from taker 0x20 | transferFrom and Aqua push 0x40).
const TAKER_EXACT_IN = "0x" + "00".repeat(20) + "0061";
const TAKER_EXACT_OUT = "0x" + "00".repeat(20) + "0060";

// ---------------------------------------------------------------- setup
const $ = (id) => document.getElementById(id);
const net = NETWORKS[DEFAULT_CHAIN_ID];
const chain = defineChain({
  id: DEFAULT_CHAIN_ID, name: net.name, nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [net.rpc] } }, blockExplorers: net.explorer ? { default: { name: "Explorer", url: net.explorer } } : undefined,
  contracts: net.multicall3 ? { multicall3: { address: net.multicall3 } } : undefined,
});
// Reads made together are sent as one Multicall3 call, which keeps the public RPC under its rate limit.
const pub = createPublicClient({ chain, transport: http(net.rpc), batch: net.multicall3 ? { multicall: true } : undefined });
const aq = net.aqua;
const order = aq && aq.order ? decodeAbiParameters([orderType], aq.order)[0] : null;
let venue = "v4";
let wallet = null, account = null, owner = null;
let key = null;
let history = [];

const fmt = (x, d = 4) => (x === null || x === undefined || Number.isNaN(x) ? "–" : Number(x).toFixed(d));
const toNum = (wad) => Number(formatUnits(wad, 18));
const tickPrice = (t) => Math.pow(1.0001, Number(t));
const sqrtToPrice = (s) => Math.pow(Number(s) / 2 ** 96, 2);
const ja = () => document.documentElement.lang === "ja";

function holdings([lower, upper, liq], p) {
  if (liq === 0n) return [0, 0];
  const L = Number(liq) / 1e18, a = Math.sqrt(tickPrice(lower)), b = Math.sqrt(tickPrice(upper));
  const s = Math.min(Math.max(Math.sqrt(p), a), b);
  return [L * (1 / s - 1 / b), L * (s - a)];
}

function log(msg, hash) {
  const link = hash && net.explorer ? ` <a target="_blank" href="${net.explorer}/tx/${hash}">tx</a>` : "";
  $("log").innerHTML = `<div>${new Date().toLocaleTimeString()} ${msg}${link}</div>` + $("log").innerHTML;
}

function setSide(box, badgeEl, on) {
  badgeEl.textContent = on ? "ON" : "STOPPED";
  badgeEl.className = "badge " + (on ? "on" : "off");
  box.className = "side " + (on ? box.id.replace("Box", "") : "stopped");
}

// ---------------------------------------------------------------- reads
async function refreshV4() {
  const r = (functionName) => pub.readContract({ address: net.hook, abi: hookAbi, functionName });
  const [state, bidOn, askOn, bid, ask, width, upper, lower, deploy, own, resBase, resQuote] = await Promise.all([
    r("bandState"), r("bidOn"), r("askOn"), r("bid"), r("ask"), r("widthBps"), r("upperBps"), r("lowerBps"), r("deployBps"), r("owner"),
    pub.readContract({ address: net.base, abi: tokenAbi, functionName: "balanceOf", args: [net.hook] }),
    pub.readContract({ address: net.quote, abi: tokenAbi, functionName: "balanceOf", args: [net.hook] }),
  ]);
  const [bidOk, askOk, priceWad, twapWad] = state;
  const price = toNum(priceWad);
  const [bb, bq] = holdings(bid, price), [ab, aqq] = holdings(ask, price);
  return {
    price, twap: toNum(twapWad), up: Number(upper) / 1e4, lo: Number(lower) / 1e4, owner: own,
    bid: bidOn && bidOk, ask: askOn && askOk,
    bidRange: bid[2] > 0n ? [tickPrice(bid[0]), tickPrice(bid[1])] : null,
    askRange: ask[2] > 0n ? [tickPrice(ask[0]), tickPrice(ask[1])] : null,
    pool: [bb + ab, bq + aqq], reserve: [toNum(resBase), toNum(resQuote)],
    width: Number(width), deploy: Number(deploy),
  };
}

async function refreshAqua() {
  const [st, bal] = await Promise.all([
    pub.readContract({ address: aq.holster, abi: holsterAquaAbi, functionName: "state", args: [aq.orderHash] }),
    pub.readContract({ address: aq.aqua, abi: aquaAbi, functionName: "safeBalances", args: [order.maker, aq.router, aq.orderHash, aq.base, aq.quote] }),
  ]);
  const price = st.live ? sqrtToPrice(st.sqrtPriceX96) : 1.0;
  const twap = st.live ? toNum(await pub.readContract({ address: aq.holster, abi: holsterAquaAbi, functionName: "twap", args: [aq.orderHash] })) : price;
  const up = aq.upperBps / 1e4, lo = aq.lowerBps / 1e4;
  const bidOk = price <= twap * (1 + up), askOk = price >= twap * (1 - lo);
  const width = st.widthBps || aq.widthBps;
  const center = st.live ? sqrtToPrice(st.sqrtCenterX96) : 1.0;
  return {
    price, twap, up, lo, owner: order.maker,
    bid: (!st.live || st.bidOn) && bidOk, ask: (!st.live || st.askOn) && askOk,
    bidRange: !st.live || st.bidLiquidity > 0n ? [st.live ? sqrtToPrice(st.sqrtLowerX96) : 1 - width / 1e4, center] : null,
    askRange: !st.live || st.askLiquidity > 0n ? [center, st.live ? sqrtToPrice(st.sqrtUpperX96) : 1 + width / 1e4] : null,
    wallet: [toNum(bal[0]), toNum(bal[1])], width, deploy: aq.deployBps,
  };
}

async function refresh() {
  if (venue === "v4" ? !net.hook : !aq || !aq.holster) return;
  const s = venue === "v4" ? await refreshV4() : await refreshAqua();
  owner = s.owner;
  $("price").textContent = fmt(s.price);
  $("twap").textContent = fmt(s.twap);
  $("band").textContent = `${fmt(s.twap * (1 - s.lo), 3)} – ${fmt(s.twap * (1 + s.up), 3)}`;
  setSide($("bidBox"), $("bidBadge"), s.bid);
  setSide($("askBox"), $("askBadge"), s.ask);
  const range = (r) => (r ? `${fmt(r[0])} – ${fmt(r[1])}` : ja() ? "ポジションなし" : "no position");
  $("bidRange").textContent = range(s.bidRange);
  $("askRange").textContent = range(s.askRange);
  $("params").textContent = `±${s.width / 100}% / ${s.deploy / 100}%`;
  if (venue === "v4") {
    const tb = s.pool[0] + s.reserve[0], tq = s.pool[1] + s.reserve[1];
    $("lpTotal").textContent = `${fmt(tb, 0)} BASE + ${fmt(tq, 0)} USDC ≈ $${fmt(tb * s.price + tq, 0)}`;
    $("lpPool").textContent = `${fmt(s.pool[0], 0)} BASE + ${fmt(s.pool[1], 0)} USDC`;
    $("lpReserve").textContent = `${fmt(s.reserve[0], 0)} BASE + ${fmt(s.reserve[1], 0)} USDC`;
  } else {
    const [b, q] = s.wallet;
    $("lpTotal").textContent = `${fmt(b, 0)} BASE + ${fmt(q, 0)} USDC ≈ $${fmt(b * s.price + q, 0)}`;
    $("lpPool").textContent = ja() ? "makerのウォレット（Aquaの枠）" : "maker's wallet (Aqua budget)";
    $("lpReserve").textContent = ja() ? `各側に最大${s.deploy / 100}%` : `up to ${s.deploy / 100}% per side`;
  }
  const isOwner = !!account && account.toLowerCase() === owner.toLowerCase();
  $("ownerPanel").hidden = !isOwner;
  $("v4Only").hidden = venue !== "v4";
  $("notOwner").hidden = isOwner;

  history.push({ t: Date.now(), price: s.price, twap: s.twap, up: s.up, lo: s.lo });
  while (history.length && history[0].t < Date.now() - WINDOW_MS) history.shift();
  draw();
}

/** Refreshes one at a time; a failed read (e.g. a rate-limited RPC) is skipped and retried on the next tick. */
let busy = false;
async function tick() {
  if (busy) return;
  busy = true;
  try { await refresh(); } catch (e) { console.warn("refresh failed", e.shortMessage || e.message); } finally { busy = false; }
}

// ---------------------------------------------------------------- chart
const WINDOW_MS = 60 * 60 * 1000; // history kept and backfilled
const viewMs = 15 * 60 * 1000; // the chart shows the last 15 minutes
const swapEvent = parseAbiItem("event Swap(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee)");

/** Rebuilds the last hour of price and TWAP from the pool's Swap logs, so the chart is not empty on load.
 *  The TWAP follows the hook's rule: the average of the last 30 finished 1-minute closes. */
async function backfillV4() {
  if (!net.poolManager) return;
  const [k, head, up, lo] = await Promise.all([
    pub.readContract({ address: net.hook, abi: hookAbi, functionName: "poolKey" }),
    pub.getBlock(),
    pub.readContract({ address: net.hook, abi: hookAbi, functionName: "upperBps" }),
    pub.readContract({ address: net.hook, abi: hookAbi, functionName: "lowerBps" }),
  ]);
  const id = keccak256(encodeAbiParameters(
    [{ type: "address" }, { type: "address" }, { type: "uint24" }, { type: "int24" }, { type: "address" }], [...k]));
  const BLOCK_S = 2, span = 5400; // 90 minutes of blocks: an hour to show, plus 30 minutes for the first TWAPs
  const from = head.number > BigInt(span / BLOCK_S) ? head.number - BigInt(span / BLOCK_S) : 0n;
  const logs = [];
  for (let b = from; b <= head.number; b += 1000n) { // the public RPC refuses wider ranges
    const to = b + 999n < head.number ? b + 999n : head.number;
    logs.push(...(await pub.getLogs({ address: net.poolManager, event: swapEvent, args: { id }, fromBlock: b, toBlock: to })));
  }
  const now = Number(head.timestamp) * 1000;
  const swaps = logs.map((l) => ({ t: now - Number(head.number - l.blockNumber) * BLOCK_S * 1000, p: sqrtToPrice(l.args.sqrtPriceX96) }));
  // the price before the first swap in the window (the pool may be younger than the window)
  const before = logs.length ? logs[0].blockNumber - 1n : head.number;
  let first;
  try { first = toNum(await pub.readContract({ address: net.hook, abi: hookAbi, functionName: "currentPrice", blockNumber: before })); }
  catch { first = swaps.length ? swaps[0].p : toNum(await pub.readContract({ address: net.hook, abi: hookAbi, functionName: "currentPrice" })); }
  const priceAt = (t) => { let p = first; for (const w of swaps) { if (w.t <= t) p = w.p; else break; } return p; };
  const pts = [];
  for (let t = now - WINDOW_MS; t <= now; t += 30_000) {
    const m = Math.floor(t / 60_000);
    let sum = 0;
    for (let j = m - 30; j < m; j++) sum += priceAt((j + 1) * 60_000 - 1);
    pts.push({ t, price: priceAt(t), twap: sum / 30, up: Number(up) / 1e4, lo: Number(lo) / 1e4 });
  }
  if (venue === "v4") { history = [...pts, ...history.filter((h) => h.t > now)]; draw(); }
}

const clock = (t) => new Date(t).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });

function draw() {
  const svg = $("chart");
  if (history.length < 2) { svg.innerHTML = ""; return; }
  const W = svg.clientWidth || 600, H = 240, L = 8, R = 62, T = 14, B = 24;
  svg.setAttribute("viewBox", `0 0 ${W} ${H}`);
  const now = history[history.length - 1].t;
  const t0 = now - viewMs;
  const data = history.filter((h) => h.t >= t0 - 30_000);
  if (data.length < 2) { svg.innerHTML = ""; return; }
  const t1 = now;
  const vals = data.flatMap((h) => [h.price, h.twap * (1 + h.up), h.twap * (1 - h.lo)]);
  let min = Math.min(...vals), max = Math.max(...vals);
  const pad = (max - min) * 0.12 || 0.01;
  min -= pad; max += pad;
  const x = (t) => L + ((t - t0) / (t1 - t0 || 1)) * (W - L - R);
  const y = (v) => T + (1 - (v - min) / (max - min)) * (H - T - B);
  const line = (f) => data.map((h) => `${x(h.t).toFixed(1)},${y(f(h)).toFixed(1)}`).join(" ");
  // the price jumps at each swap, so it is drawn as steps
  const steps = (f) => data.map((h, i) => (i ? `${x(h.t).toFixed(1)},${y(f(data[i - 1])).toFixed(1)} ` : "") + `${x(h.t).toFixed(1)},${y(f(h)).toFixed(1)}`).join(" ");

  const last = data[data.length - 1];
  const gap = y(last.twap) - y(last.price), nudge = Math.abs(gap) < 20 ? (gap >= 0 ? -1 : 1) * (20 - Math.abs(gap)) / 2 : 0;
  const pillYs = [y(last.price) + nudge, y(last.twap) - nudge];

  let g = "";
  // grid and price labels (a label under a current-value pill is left out)
  for (let k = 0; k <= 4; k++) {
    const v = min + ((max - min) * k) / 4, yy = y(v);
    g += `<line x1="${L}" x2="${W - R}" y1="${yy}" y2="${yy}" stroke="var(--line)" stroke-width="1"/>`;
    if (pillYs.every((py) => Math.abs(py - yy) > 16)) g += `<text x="${W - R + 8}" y="${yy + 4}" class="axis">${v.toFixed(3)}</text>`;
  }
  for (let k = 0; k <= 3; k++) {
    const t = t0 + ((now - t0) * k) / 3;
    g += `<text x="${x(t)}" y="${H - 6}" class="axis" text-anchor="${k === 0 ? "start" : k === 3 ? "end" : "middle"}">${clock(t)}</text>`;
  }
  // periods where the price was outside the band: one side stopped
  let run = null;
  const flush = (end) => { if (run) g += `<rect x="${x(run.t)}" y="${T}" width="${Math.max(2, x(end) - x(run.t))}" height="${H - T - B}" fill="var(--ask)" fill-opacity="0.07"/>`; run = null; };
  for (const h of data) {
    const out = h.price > h.twap * (1 + h.up) || h.price < h.twap * (1 - h.lo);
    if (out && !run) run = h; else if (!out && run) flush(h.t);
  }
  flush(now);
  // band, TWAP, price
  const upper = line((h) => h.twap * (1 + h.up)), lower = data.map((h) => `${x(h.t).toFixed(1)},${y(h.twap * (1 - h.lo)).toFixed(1)}`).reverse().join(" ");
  g += `<defs><linearGradient id="pfill" x1="0" x2="0" y1="0" y2="1"><stop offset="0" stop-color="var(--ink)" stop-opacity="0.10"/><stop offset="1" stop-color="var(--ink)" stop-opacity="0"/></linearGradient></defs>
    <polygon points="${upper} ${lower}" fill="var(--band)" fill-opacity="0.13"/>
    <polyline points="${upper}" fill="none" stroke="var(--band)" stroke-width="1" stroke-dasharray="3 4" stroke-opacity="0.7"/>
    <polyline points="${lower.split(" ").reverse().join(" ")}" fill="none" stroke="var(--band)" stroke-width="1" stroke-dasharray="3 4" stroke-opacity="0.7"/>
    <polygon points="${x(data[0].t)},${H - B} ${steps((h) => h.price)} ${x(now)},${H - B}" fill="url(#pfill)"/>
    <polyline points="${line((h) => h.twap)}" fill="none" stroke="var(--band)" stroke-width="2" stroke-linejoin="round"/>
    <polyline points="${steps((h) => h.price)}" fill="none" stroke="var(--ink)" stroke-width="2" stroke-linejoin="round"/>`;
  // current values, labelled at the right edge
  const PW = R - 5, px0 = W - R + 3; // current values sit on the price axis
  const pill = (v, color, dy = 0) => `<rect x="${px0}" y="${y(v) - 9 + dy}" width="${PW}" height="18" rx="9" fill="${color}"/>
    <text x="${px0 + PW / 2}" y="${y(v) + 4 + dy}" class="pill" text-anchor="middle">${v.toFixed(4)}</text>`;
  g += `<circle cx="${x(now)}" cy="${y(last.price)}" r="4" fill="var(--ink)" stroke="var(--surface)" stroke-width="2"/>
    ${pill(last.twap, "var(--band)", -nudge)}${pill(last.price, "var(--ink)", nudge)}
    <g id="hover" visibility="hidden"><line id="hx" y1="${T}" y2="${H - B}" stroke="var(--muted)" stroke-dasharray="2 3"/><circle id="hp" r="4" fill="var(--ink)"/><circle id="ht" r="4" fill="var(--band)"/></g>`;
  svg.innerHTML = g;

  // hover: crosshair and a tooltip with the values at that time
  svg.onmousemove = (e) => {
    const r = svg.getBoundingClientRect(), px = ((e.clientX - r.left) / r.width) * W;
    const t = Math.min(now, t0 + ((px - L) / (W - L - R)) * (t1 - t0));
    let h = data[0];
    for (const c of data) { if (c.t <= t) h = c; else break; }
    const hv = svg.querySelector("#hover");
    hv.setAttribute("visibility", "visible");
    svg.querySelector("#hx").setAttribute("x1", x(h.t)); svg.querySelector("#hx").setAttribute("x2", x(h.t));
    svg.querySelector("#hp").setAttribute("cx", x(h.t)); svg.querySelector("#hp").setAttribute("cy", y(h.price));
    svg.querySelector("#ht").setAttribute("cx", x(h.t)); svg.querySelector("#ht").setAttribute("cy", y(h.twap));
    const tip = $("chartTip");
    tip.hidden = false;
    tip.innerHTML = `<b>${clock(h.t)}</b><br>${ja() ? "価格" : "price"} <span class="mono">${h.price.toFixed(4)}</span><br>TWAP <span class="mono">${h.twap.toFixed(4)}</span><br>band <span class="mono">${(h.twap * (1 - h.lo)).toFixed(3)} – ${(h.twap * (1 + h.up)).toFixed(3)}</span>`;
    const left = (x(h.t) / W) * r.width;
    tip.style.left = `${Math.min(Math.max(left + 12, 0), r.width - 170)}px`;
    tip.style.top = `${(y(h.price) / H) * r.height - 20}px`;
  };
  svg.onmouseleave = () => { svg.querySelector("#hover")?.setAttribute("visibility", "hidden"); $("chartTip").hidden = true; };
}
window.addEventListener("resize", draw);

// ---------------------------------------------------------------- writes
async function send(label, request) {
  const { request: req } = await pub.simulateContract({ account, ...request });
  const hash = await wallet.writeContract(req);
  log(`${label}: sent`, hash);
  await pub.waitForTransactionReceipt({ hash });
  log(`${label}: confirmed`, hash);
}

async function run(label, f) {
  if (!wallet) return log(ja() ? "先にウォレットを接続してください" : "Connect a wallet first");
  try {
    await f();
    await tick();
    setTimeout(tick, 2500); // the public RPC can lag a block behind the receipt
  } catch (e) {
    log(`${label}: ${e.shortMessage || e.message}`);
  }
}

/** Mints demo tokens and approves the venue's router when needed, so a pump or dump is a single click. */
async function prepareTrader(base, quote, spender) {
  for (const [sym, token] of [["BASE", base], ["USDC", quote]]) {
    const bal = await pub.readContract({ address: token, abi: tokenAbi, functionName: "balanceOf", args: [account] });
    if (bal < parseUnits("100000", 18)) { // a pump or dump uses tens of thousands, so mint enough for many
      await send(`Get test ${sym}`, { address: token, abi: tokenAbi, functionName: "mint", args: [account, parseUnits("10000000", 18)] });
    }
    const allowance = await pub.readContract({ address: token, abi: tokenAbi, functionName: "allowance", args: [account, spender] });
    if (allowance < parseUnits("1000000", 18)) {
      await send(`Approve ${sym}`, { address: token, abi: tokenAbi, functionName: "approve", args: [spender, maxUint256] });
    }
  }
}

/** Moves the Holster pool's price by `factor`. */
async function v4SwapTo(label, factor) {
  await prepareTrader(net.base, net.quote, net.router);
  if (!key) {
    const k = await pub.readContract({ address: net.hook, abi: hookAbi, functionName: "poolKey" });
    key = { currency0: k[0], currency1: k[1], fee: k[2], tickSpacing: k[3], hooks: k[4] };
  }
  const state = await pub.readContract({ address: net.hook, abi: hookAbi, functionName: "bandState" });
  const target = toNum(state[2]) * factor;
  await send(`${label} to ${fmt(target)}`, {
    address: net.router, abi: v4RouterAbi, functionName: "swap",
    args: [key, factor < 1, -(10n ** 30n), BigInt(Math.floor(Math.sqrt(target) * 2 ** 96))],
  });
}

/** Aqua: buy BASE (exact out) or sell BASE (exact in). A quote first: if Holster refuses, nothing is sent. */
async function aquaTrade(label, buy, amount) {
  await prepareTrader(aq.base, aq.quote, aq.router);
  const [tokenIn, tokenOut] = buy ? [aq.quote, aq.base] : [aq.base, aq.quote];
  const taker = buy ? TAKER_EXACT_OUT : TAKER_EXACT_IN;
  const args = [order, tokenIn, tokenOut, parseUnits(String(amount), 18), taker];
  try {
    await pub.simulateContract({ account, address: aq.router, abi: swapVmAbi, functionName: "quote", args });
  } catch {
    return log(ja() ? `${label}: Holsterが断った（bandがこの側を止めている）` : `${label}: refused by Holster (the band stops this side)`);
  }
  await send(label, { address: aq.router, abi: swapVmAbi, functionName: "swap", args });
}

$("connect").onclick = async () => {
  if (!window.ethereum) return log("No wallet found (install MetaMask or similar)");
  wallet = createWalletClient({ chain, transport: custom(window.ethereum) });
  [account] = await wallet.requestAddresses();
  try { await wallet.switchChain({ id: chain.id }); } catch { await wallet.addChain({ chain }); }
  $("account").textContent = `${account.slice(0, 6)}…${account.slice(-4)}`;
  $("connect").textContent = ja() ? "接続済み" : "Connected";
  tick();
};
$("pump").onclick = () => run("Pump", () => (venue === "v4" ? v4SwapTo("Pump", 1.15) : aquaTrade("Buy 3,000 BASE", true, 3000)));
$("dump").onclick = () => run("Dump", () => (venue === "v4" ? v4SwapTo("Dump", 0.87) : aquaTrade("Sell 1,500 BASE", false, 1500)));
$("deposit").onclick = () => run("Provide liquidity", async () => {
  const b = parseUnits($("depBase").value || "0", 18), q = parseUnits($("depQuote").value || "0", 18);
  await send("Approve BASE for the hook", { address: net.base, abi: tokenAbi, functionName: "approve", args: [net.hook, b] });
  await send("Approve USDC for the hook", { address: net.quote, abi: tokenAbi, functionName: "approve", args: [net.hook, q] });
  await send("Provide liquidity", { address: net.hook, abi: hookAbi, functionName: "deposit", args: [b, q] });
});
$("withdraw").onclick = () => run("Withdraw", () => send("Withdraw all", { address: net.hook, abi: hookAbi, functionName: "withdraw" }));
$("setWidth").onclick = () => run("Set width", () => {
  const bps = Math.round(Number($("widthIn").value) * 100);
  return venue === "v4"
    ? send(`Set width ±${$("widthIn").value}%`, { address: net.hook, abi: hookAbi, functionName: "setWidth", args: [BigInt(bps)] })
    : send(`Set width ±${$("widthIn").value}%`, { address: aq.holster, abi: holsterAquaAbi, functionName: "setWidth", args: [aq.orderHash, bps] });
});

// ---------------------------------------------------------------- venue switch
const NOTES = {
  v4: ["The hook holds the LP's funds and moves its two positions in the pool before each swap.",
       "hookがLPの資金を預かり、swapの直前にプール内の2つのポジションを動かす。"],
  aqua: ["The LP's funds stay in its wallet. Holster prices every quote; a stopped side is refused. Aqua and the SwapVM router (v1.0.2) are deployed from 1inch's source, since 1inch has no official testnet.",
         "LPの資金はウォレットのまま。Holsterが見積もりのたびに値段を決め、止めた側は断る。1inchに公式のテストネットがないため、AquaとSwapVMルーター（v1.0.2）は公式のソースからデプロイしている。"],
};
function setVenue(v) {
  venue = v;
  history = [];
  $("chart").innerHTML = "";
  if (v === "v4") backfillV4().catch((e) => console.warn("backfill failed", e.shortMessage || e.message));
  $("venueV4").classList.toggle("on", v === "v4");
  $("venueAqua").classList.toggle("on", v === "aqua");
  $("venueNote").textContent = NOTES[v][ja() ? 1 : 0];
  $("pump").textContent = v === "v4" ? (ja() ? "パンプ +15%" : "Pump +15%") : (ja() ? "3,000 BASEを買う" : "Buy 3,000 BASE");
  $("dump").textContent = v === "v4" ? (ja() ? "ダンプ −13%" : "Dump −13%") : (ja() ? "1,500 BASEを売る" : "Sell 1,500 BASE");
  tick();
}
$("venueV4").onclick = () => setVenue("v4");
$("venueAqua").onclick = () => setVenue("aqua");
new MutationObserver(() => setVenue(venue)).observe(document.documentElement, { attributes: true, attributeFilter: ["lang"] });

if (!net.hook) {
  $("config-notice").hidden = false;
  $("config-notice").textContent = `No deployment configured for ${net.name}. Deploy with contracts/script/DeployV4.s.sol, then run node frontend/sync-config.mjs.`;
} else {
  setVenue("v4");
  setInterval(tick, 4000);
}
