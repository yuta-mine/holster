import { NETWORKS, DEFAULT_CHAIN_ID } from "./config.js";

const $ = (id) => document.getElementById(id);
const net = NETWORKS[DEFAULT_CHAIN_ID];

// ---------------------------------------------------------------- language (English / Japanese)
let lang = "en";
try { lang = localStorage.getItem("holster-lang") || "en"; } catch {}
const t = (en, ja) => (lang === "ja" ? ja : en);

function applyStaticLang() {
  document.documentElement.lang = lang;
  document.querySelectorAll("[data-ja]").forEach((el) => {
    if (!el.dataset.en) el.dataset.en = el.innerHTML;
    el.innerHTML = lang === "ja" ? el.dataset.ja : el.dataset.en;
  });
  $("langToggle").textContent = lang === "ja" ? "English" : "日本語";
}
$("langToggle").onclick = () => {
  lang = lang === "ja" ? "en" : "ja";
  try { localStorage.setItem("holster-lang", lang); } catch {}
  applyStaticLang();
  render();
};

// ---------------------------------------------------------------- routing between the two views
function route() {
  const sandbox = location.hash === "#live" || location.hash === "#sandbox";
  $("story").hidden = sandbox;
  $("sandbox").hidden = !sandbox;
  $("navStory").classList.toggle("active", !sandbox);
  $("navSandbox").classList.toggle("active", sandbox);
}
window.addEventListener("hashchange", route);

// ---------------------------------------------------------------- step 3: positions on a price axis
const LO = 0.85, HI = 1.3;
const STATES = () => [
  {
    label: t("Start", "最初"), price: 1.0,
    holster: [["bid", 0.9, 1.0], ["ask", 1.0, 1.1]], recenter: [["bid", 0.9, 1.0], ["ask", 1.0, 1.1]],
    text: t("Both LPs quote a bid below 1.00 and an ask above it.", "どちらのLPも、1.00の下に買い側、上に売り側を置いている。"),
  },
  {
    label: t("Pump to 1.15", "1.15までパンプ"), price: 1.15,
    holster: [["bid", 0.9, 1.0], ["sold", 1.0, 1.1]], recenter: [["bid", 0.9, 1.0], ["sold", 1.0, 1.1]],
    text: t("The price is pumped to 1.15 within a minute. The TWAP is still 1.00.", "1分のうちに1.15まで買い上げられる。TWAPはまだ1.00。"),
  },
  {
    label: t("Before the next swap", "次のswapの直前"), price: 1.15,
    holster: [["off", 0.9, 1.15], ["ask", 1.15, 1.265]], recenter: [["bid", 1.035, 1.15], ["ask", 1.15, 1.265]],
    text: t("1.15 is 15% above the TWAP: Holster pulls its bid. The re-centering LP puts its bid right under the top.",
            "1.15はTWAPより15%上なので、Holsterは買い側を引き上げる。張り直すLPは、高値の真下に買い側を置く。"),
  },
  {
    label: t("Dump to 1.00", "1.00までダンプ"), price: 1.0,
    holster: [["ask", 1.15, 1.265]], recenter: [["filled", 1.0, 1.15], ["ask", 1.15, 1.265]],
    text: t("The dump misses Holster. The re-centering LP buys all the way down from 1.15.",
            "売り浴びせはHolsterに当たらない。張り直すLPは1.15から下まで買わされる。"),
  },
  {
    label: t("Back inside the band", "bandの中に戻る"), price: 1.0,
    holster: [["bid", 0.9, 1.0], ["ask", 1.0, 1.1]], recenter: [["filled", 1.0, 1.15], ["ask", 1.15, 1.265]],
    text: t("Both sides return around 1.00. On the real v4 PoolManager: Holster +396 USDC, re-centering LP −227 USDC.",
            "1.00の周りに両側が戻る。本物のv4 PoolManager上で、Holster +396 USDC、張り直すLP −227 USDC。"),
  },
];
const COLORS = { bid: "var(--bid)", ask: "var(--ask)", sold: "var(--muted)", filled: "var(--ask)", off: "var(--line)" };

function positionsSvg(s) {
  const W = 620, H = 210, L = 110, R = 16;
  const x = (p) => L + ((p - LO) / (HI - LO)) * (W - L - R);
  const rows = [["Holster", s.holster, 40], [t("Re-centering LP", "張り直すLP"), s.recenter, 110]];
  const names = { bid: t("bid", "買い側"), ask: t("ask", "売り側"), sold: t("sold", "売った"), filled: t("bought high", "高値で買った"), off: t("bid off", "買い側を停止") };
  let g = "";
  for (let p = 0.9; p <= 1.3001; p += 0.1) {
    g += `<line x1="${x(p)}" x2="${x(p)}" y1="20" y2="175" stroke="var(--line)"/>
          <text x="${x(p)}" y="195" font-size="12" fill="var(--muted)" text-anchor="middle">${p.toFixed(2)}</text>`;
  }
  for (const [name, ranges, y] of rows) {
    g += `<text x="0" y="${y + 24}" font-size="13" font-weight="600" fill="var(--ink)">${name}</text>`;
    for (const [kind, a, b] of ranges) {
      const style = kind === "sold" || kind === "off" ? ' stroke-dasharray="4 3" fill-opacity="0.15"' : kind === "filled" ? ' fill-opacity="0.45"' : "";
      g += `<rect x="${x(a)}" y="${y}" width="${x(b) - x(a)}" height="40" rx="6" fill="${COLORS[kind]}" stroke="${COLORS[kind]}"${style}/>
            <text x="${(x(a) + x(b)) / 2}" y="${y + 25}" font-size="12" text-anchor="middle" fill="${kind === "off" || kind === "sold" ? "var(--muted)" : "#fff"}">${names[kind]}</text>`;
    }
  }
  g += `<line x1="${x(s.price)}" x2="${x(s.price)}" y1="14" y2="175" stroke="var(--accent)" stroke-width="3"/>
        <text x="${x(s.price)}" y="12" font-size="12" font-weight="700" fill="var(--accent)" text-anchor="middle">${t("price", "価格")} ${s.price.toFixed(2)}</text>`;
  return `<svg viewBox="0 0 ${W} ${H}" width="100%" role="img" aria-label="LP positions">${g}</svg>`;
}

let sub = 0;
function mountPositions(root) {
  const states = STATES();
  root.querySelector(".substeps").innerHTML = states.map((s, k) => `<button class="${k === sub ? "on" : ""}" data-k="${k}">${k + 1}. ${s.label}</button>`).join("");
  root.querySelector(".diagram").innerHTML = positionsSvg(states[sub]);
  root.querySelector(".caption").textContent = states[sub].text;
  root.querySelectorAll(".substeps button").forEach((b) => (b.onclick = () => { sub = +b.dataset.k; mountPositions(root); }));
}

// ---------------------------------------------------------------- the story
const STEPS = () => [
  {
    tab: t("The problem", "課題"),
    copy: t(`<h1>LPs keep quoting through a pump</h1>
      <p>An attacker pumps a thin token. The LP re-centers around the new top, so a fresh bid sits right under it. Then the attacker dumps into that bid.</p>
      <p>The LP buys high. Existing defenses raise fees or halt the whole pool; none lets an LP stop only its losing side.</p>`,
      `<h1>LPはパンプの最中も流動性を出し続ける</h1>
      <p>攻撃者が流動性の少ないトークンを買い上げる。LPは新しい高値の周りに置き直すので、高値の真下に買い側ができる。そこへ攻撃者が売り浴びせる。</p>
      <p>LPは高値で買わされる。既存の対策は手数料を上げるかプール全体を止めるもので、LPが不利な側だけを止める仕組みはない。</p>`),
    visual: `<div class="flow">
        <div class="box bad"><div class="who">${t("Attacker", "攻撃者")}</div>${t("<b>Pumps</b> 1.00 → 1.15", "1.00 → 1.15に<b>買い上げる</b>")}</div>
        <div class="arrow">↓</div>
        <div class="box"><div class="who">${t("LP (re-centers)", "LP（張り直す）")}</div>${t("<b>Moves its bid</b> right under 1.15", "1.15の真下に<b>買い側を置き直す</b>")}</div>
        <div class="arrow">↓</div>
        <div class="box bad"><div class="who">${t("Attacker", "攻撃者")}</div>${t("<b>Dumps</b> back to 1.00 into that bid", "その買い側に<b>売り浴びせて</b>1.00へ")}</div>
      </div>
      <div class="big"><b>−227 USDC</b>${t("for the re-centering LP in one round trip", "張り直すLPの、1往復での損益")}</div>`,
  },
  {
    tab: t("The idea", "考え方"),
    copy: t(`<h1>Don't buy the pump. Don't sell the dump.</h1>
      <p>Compare the price with a 30-minute TWAP recorded on-chain. The TWAP trails the price, so sudden moves land outside the band.</p>
      <p><b style="color:var(--ask)">Above the band</b>: no bids. <b style="color:var(--bid)">Below</b>: no asks. Back inside: both sides return.</p>`,
      `<h1>パンプで買わない。ダンプで売らない。</h1>
      <p>価格を、オンチェーンで記録した30分のTWAPと比べる。TWAPは価格に遅れてついてくるので、急な動きはbandの外に出る。</p>
      <p><b style="color:var(--ask)">bandより上</b>では買わない。<b style="color:var(--bid)">下</b>では売らない。中に戻れば両側を戻す。</p>`),
    visual: `<img src="./assets/band.${lang}.svg" alt="TWAP band" />`,
  },
  {
    tab: t("How it reacts", "動き"),
    copy: t(`<h1>Pull the losing side before the next swap</h1>
      <p>The LP holds a one-sided bid below the price and an ask above it. Right before every swap the hook checks the band and re-places the allowed sides next to the price.</p>`,
      `<h1>次のswapの前に、不利な側を引き上げる</h1>
      <p>LPは、価格の下に買い側、上に売り側を、それぞれ片側だけのポジションで持つ。swapの直前に毎回hookがbandを確かめ、出してよい側を価格の隣に置き直す。</p>`),
    visual: `<div class="card"><div class="substeps"></div><div class="diagram"></div><div class="caption"></div></div>`,
    mount: (root) => mountPositions(root.querySelector(".card")),
  },
  {
    tab: t("How it's built", "実装"),
    copy: t(`<h1>One rule set, two venues</h1>
      <p>The same band runs fully on-chain on Uniswap v4 and 1inch Aqua. No keeper is needed.</p>`,
      `<h1>同じルールを、2つの場所で</h1>
      <p>同じbandが、Uniswap v4と1inch Aquaの上ですべてオンチェーンで動く。keeperは不要。</p>`),
    visual: `<div class="two">
        <div class="dark"><h3>Uniswap v4 hook</h3><ul>
          <li>${t("Holds the LP's funds as two positions", "LPの資金を2つのポジションで持つ")}</li>
          <li>${t("<code>beforeSwap</code>: check the band, re-place", "<code>beforeSwap</code>でbandを確認し置き直す")}</li>
          <li>${t("Live on Base Sepolia", "Base Sepoliaで稼働中")}</li></ul></div>
        <div class="dark"><h3>1inch Aqua</h3><ul>
          <li>${t("One SwapVM <code>Extruction</code> prices every quote", "SwapVMの<code>Extruction</code>1つで見積もる")}</li>
          <li>${t("Funds stay in the maker's wallet", "資金はmakerのウォレットのまま")}</li>
          <li>${t("Re-placing costs no gas", "置き直しにガス代がかからない")}</li></ul></div>
      </div>
      <div class="big" style="margin-top:16px"><b>23</b>${t("Foundry tests on the real v4 PoolManager and Aqua", "本物のv4 PoolManagerとAqua上のFoundryテスト")}</div>`,
  },
  {
    tab: t("Backtest", "バックテスト"),
    copy: t(`<h1>Tested on real swaps</h1>
      <p>NEAR, PONS, BaseCat and LIT swaps replayed with fees and gas. Holster beat the re-centering LP on all four data sets.</p>`,
      `<h1>実際のswapで検証</h1>
      <p>NEAR・PONS・BaseCat・LITのswapを、手数料とガス代込みで再生。Holsterは4つとも、張り直すLPを上回った。</p>`),
    visual: `<table class="res">
        <tr><th></th><th>NEAR 30d</th><th>PONS 16d</th><th>BaseCat 30d</th><th>LIT 30d</th></tr>
        <tr><td>${t("Re-centering LP", "張り直すLP")}</td><td>+0.6%</td><td>−5.4%</td><td>+56.5%</td><td>−34.7%</td></tr>
        <tr class="hl"><td>Holster</td><td>+71.0%</td><td>+4.6%</td><td>+75.3%</td><td>+24.5%</td></tr>
        <tr><td class="muted">${t("Fixed ranges (hindsight)", "固定レンジ（後出し）")}</td><td class="muted">+51.6%</td><td class="muted">+13.5%</td><td class="muted">+67.3%</td><td class="muted">+26.9%</td></tr>
      </table>
      <img src="./assets/near-pnl.svg" alt="NEAR P&L" style="margin-top:14px" />`,
  },
  {
    tab: t("Live demo", "ライブデモ"),
    copy: t(`<h1>Live on Base Sepolia</h1>
      <p>Pump the price on the live page and watch the bid switch off. The TWAP catches up within minutes and both sides return.</p>
      <p><button class="primary" onclick="location.hash='#live'">Open the live demo →</button></p>`,
      `<h1>Base Sepoliaで稼働中</h1>
      <p>「Base Sepoliaで動かす」で価格を買い上げると、買い側が止まる。数分でTWAPが追いつき、両側が戻る。</p>
      <p><button class="primary" onclick="location.hash='#live'">ライブデモを開く →</button></p>`),
    visual: `<div class="dark"><h3>${t("Contracts on Base Sepolia", "Base Sepoliaのコントラクト")}</h3><ul class="mono" style="font-size:13px">
        ${[["HolsterHook", net.hook], ["PoolManager (Uniswap)", "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408"], ["BASE", net.base], ["USDC", net.quote]]
          .map(([n, a]) => `<li>${n}<br/><a style="color:var(--dark-ink)" target="_blank" href="${net.explorer}/address/${a}">${a || "–"}</a></li>`).join("")}
      </ul></div>
      <p class="muted small">github.com/yuta-mine/holster</p>`,
  },
  {
    tab: t("Open questions", "今後の課題"),
    copy: t(`<h1>What's next</h1>
      <p>Holster rarely loses, but these need more work before production.</p>`,
      `<h1>今後の課題</h1>
      <p>Holsterは負けにくいが、実用の前に詰めるべき点がある。</p>`),
    visual: `<div class="flow">
        <div class="box"><div class="who">${t("Other LPs", "他のLP")}</div>${t("While a side is stopped, other LPs take those trades. If most of a pool used Holster, results could change.",
          "片側を止めている間の取引は他のLPが受ける。プールの多くがHolsterになると、結果は変わりうる。")}</div>
        <div class="box"><div class="who">${t("Deployed share", "出す割合")}</div>${t("Results depend a lot on how much is deployed. 75% balanced well, but it was not optimized.",
          "結果は出す割合で大きく変わる。75%がバランス良かったが、最適化はしていない。")}</div>
        <div class="box"><div class="who">${t("Gas", "ガス代")}</div>${t("Re-placing costs more gas than a plain LP. Small on L2; none on Aqua.",
          "置き直す分、普通のLPよりガス代がかかる。L2では小さく、Aquaではかからない。")}</div>
      </div>`,
  },
];

let step = 0;
function render() {
  const steps = STEPS();
  $("stepTabs").innerHTML = steps.map((s, k) => `<li class="${k === step ? "active" : ""}" data-k="${k}">${k + 1} · ${s.tab}</li>`).join("");
  $("stepTabs").querySelectorAll("li").forEach((li) => (li.onclick = () => { step = +li.dataset.k; render(); }));
  $("stepCopy").innerHTML = steps[step].copy;
  $("stepVisual").innerHTML = steps[step].visual;
  if (steps[step].mount) steps[step].mount($("stepVisual"));
  $("stepCount").textContent = t(`Step ${step + 1} of ${steps.length}`, `${step + 1} / ${steps.length}`);
  $("prev").textContent = t("← Prev", "← 前へ");
  $("prev").disabled = step === 0;
  $("next").textContent = step === steps.length - 1 ? t("↺ Restart", "↺ 最初から") : t("Next →", "次へ →");
}
$("prev").onclick = () => { if (step > 0) { step--; render(); } };
$("next").onclick = () => { step = step === STEPS().length - 1 ? 0 : step + 1; render(); };

applyStaticLang();
render();
route();
