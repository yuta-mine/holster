import {
  createPublicClient, createWalletClient, custom, http, formatUnits, parseUnits, maxUint256, defineChain, decodeAbiParameters,
} from "https://esm.sh/viem@2.21.55";
import { NETWORKS, DEFAULT_CHAIN_ID } from "./config.js";

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
  fn("deployBps", [], ["uint256"]), fn("owner", [], ["address"]),
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
});
const pub = createPublicClient({ chain, transport: http(net.rpc) });
const aq = net.aqua;
const order = aq && aq.order ? decodeAbiParameters([orderType], aq.order)[0] : null;
let venue = "v4";
let wallet = null, account = null, key = null, lastPrice = null, owner = null;
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
  lastPrice = s.price;
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

  history.push({ price: s.price, twap: s.twap, up: s.up, lo: s.lo });
  if (history.length > 240) history.shift();
  draw();
}

function draw() {
  if (history.length < 2) return;
  const vals = history.flatMap((h) => [h.price, h.twap * (1 + 2.5 * h.up), h.twap * (1 - 2.5 * h.lo)]); // room around the band
  let min = Math.min(...vals), max = Math.max(...vals);
  const pad = (max - min) * 0.1 || 0.01;
  min -= pad; max += pad;
  const x = (i) => (i / (history.length - 1)) * 600;
  const y = (v) => 212 - ((v - min) / (max - min)) * 204;
  const up = history.map((h, i) => `${x(i)},${y(h.twap * (1 + h.up))}`).join(" ");
  const lo = history.map((h, i) => `${x(i)},${y(h.twap * (1 - h.lo))}`).reverse().join(" ");
  $("chart").innerHTML = `
    <polygon points="${up} ${lo}" fill="var(--band)" fill-opacity="0.16" />
    <polyline points="${history.map((h, i) => `${x(i)},${y(h.twap)}`).join(" ")}" fill="none" stroke="var(--band)" stroke-width="2" vector-effect="non-scaling-stroke" />
    <polyline points="${history.map((h, i) => `${x(i)},${y(h.price)}`).join(" ")}" fill="none" stroke="var(--ink)" stroke-width="1.6" vector-effect="non-scaling-stroke" />`;
}

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
    await refresh();
  } catch (e) {
    log(`${label}: ${e.shortMessage || e.message}`);
  }
}

/** Mints demo tokens and approves the venue's router when needed, so a pump or dump is a single click. */
async function prepareTrader(base, quote, spender) {
  for (const [sym, token] of [["BASE", base], ["USDC", quote]]) {
    const bal = await pub.readContract({ address: token, abi: tokenAbi, functionName: "balanceOf", args: [account] });
    if (bal < parseUnits("50000", 18)) {
      await send(`Get test ${sym}`, { address: token, abi: tokenAbi, functionName: "mint", args: [account, parseUnits("100000", 18)] });
    }
    const allowance = await pub.readContract({ address: token, abi: tokenAbi, functionName: "allowance", args: [account, spender] });
    if (allowance < parseUnits("1000000", 18)) {
      await send(`Approve ${sym}`, { address: token, abi: tokenAbi, functionName: "approve", args: [spender, maxUint256] });
    }
  }
}

async function v4SwapTo(label, factor) {
  await prepareTrader(net.base, net.quote, net.router);
  if (!key) {
    const k = await pub.readContract({ address: net.hook, abi: hookAbi, functionName: "poolKey" });
    key = { currency0: k[0], currency1: k[1], fee: k[2], tickSpacing: k[3], hooks: k[4] };
  }
  const target = lastPrice * factor;
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
  refresh();
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
  $("venueV4").classList.toggle("on", v === "v4");
  $("venueAqua").classList.toggle("on", v === "aqua");
  $("venueNote").textContent = NOTES[v][ja() ? 1 : 0];
  $("pump").textContent = v === "v4" ? (ja() ? "パンプ +15%" : "Pump +15%") : (ja() ? "3,000 BASEを買う" : "Buy 3,000 BASE");
  $("dump").textContent = v === "v4" ? (ja() ? "ダンプ −13%" : "Dump −13%") : (ja() ? "1,500 BASEを売る" : "Sell 1,500 BASE");
  refresh();
}
$("venueV4").onclick = () => setVenue("v4");
$("venueAqua").onclick = () => setVenue("aqua");
new MutationObserver(() => setVenue(venue)).observe(document.documentElement, { attributes: true, attributeFilter: ["lang"] });

if (!net.hook) {
  $("config-notice").hidden = false;
  $("config-notice").textContent = `No deployment configured for ${net.name}. Deploy with contracts/script/DeployV4.s.sol, then run node frontend/sync-config.mjs.`;
} else {
  setVenue("v4");
  setInterval(refresh, 4000);
}
