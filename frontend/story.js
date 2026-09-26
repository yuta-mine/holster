// Loaded fresh on every visit: the addresses change whenever the demo is set up again (init-demo.sh).
const { NETWORKS, DEFAULT_CHAIN_ID } = await import(`./config.js?v=${Date.now()}`);

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
    text: t("Both sides return around 1.00.",
            "1.00の周りに両側が戻る。"),
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
    copy: t(`<h1>Stay put, or re-center?</h1>
      <p>A static LP loses nothing when the price comes back, but earns no fees out of range.</p>
      <p>A re-centering LP keeps earning, but the bid it re-places at the top gets dumped on.</p>
      <p><b>Is there a way to LP that beats both?</b></p>`,
      `<h1>置いたままか、張り直すか</h1>
      <p>置いたままのLPは、価格が戻れば損はないが、範囲外では手数料が入らない。</p>
      <p>張り直し続けると手数料は取れるが、パンプの頂点で置き直した買い側に売り浴びせられる。</p>
      <p><b>両方より良いLPの仕方はないか？</b></p>`),
    visual: `<div class="two">
        <div class="flow"><div class="box"><div class="who">${t("Static LP", "置いたままのLP")}</div>
          <div class="num"><b>±0</b>${t("+ fees", "＋手数料")}</div>
          ${t("No fees while out of range", "範囲外では手数料が入らない")}</div></div>
        <div class="flow"><div class="box bad"><div class="who">${t("Re-centering LP", "張り直すLP")}</div>
          <div class="num loss"><b>−1,115</b>USDC</div>
          ${t("Re-places at the top and buys high", "頂点で置き直して、高値で買わされる")}</div></div>
      </div>
      <p class="muted small">${t("Test on Uniswap v4: a $20,000 LP, one round trip 1.00 → 1.15 → 1.00.",
        "Uniswap v4上のテスト。$20,000のLPで、1.00 → 1.15 → 1.00を1往復。")}</p>`,
  },
  {
    tab: t("The idea", "考え方"),
    copy: t(`<h1>Don't buy the pump. Don't sell the dump.</h1>
      <p>Holster compares the price with a 30-minute TWAP recorded on-chain. The TWAP trails the price, so sudden moves land outside the band.</p>
      <p><b style="color:var(--ask)">Above the band</b>: no bids. <b style="color:var(--bid)">Below</b>: no asks. Back inside: both sides return.</p>`,
      `<h1>パンプで買わない。ダンプで売らない。</h1>
      <p>Holsterは、価格をオンチェーンで記録した30分のTWAPと比べる。TWAPは価格に遅れてついてくるので、急な動きはbandの外に出る。</p>
      <p><b style="color:var(--ask)">bandより上</b>では買わない。<b style="color:var(--bid)">下</b>では売らない。中に戻れば両側を戻す。</p>`),
    visual: `<img src="./assets/band.${lang}.svg" alt="TWAP band" />`,
  },
  {
    tab: t("How it reacts", "動き"),
    copy: t(`<h1>Pull the losing side before the next swap</h1>
      <p>The LP holds a one-sided bid below the price and an ask above it. Right before every swap the hook checks the band and re-places the allowed sides next to the price.</p>
      <p>A re-centering LP puts its bid right under a spike. Holster doesn't.</p>`,
      `<h1>次のswapの前に、不利な側を引き上げる</h1>
      <p>LPは、価格の下に買い側、上に売り側を、それぞれ片側だけのポジションで持つ。swapの直前に毎回hookがbandを確かめ、出してよい側を価格の隣に置き直す。</p>
      <p>張り直すLPは急騰の真下に買い側を置き直すが、Holsterは置かない。</p>`),
    visual: `<div class="card"><div class="substeps"></div><div class="diagram"></div><div class="caption"></div></div>`,
    mount: (root) => mountPositions(root.querySelector(".card")),
  },
  {
    tab: t("How it's built", "実装"),
    copy: t(`<h1>One rule set, two venues</h1>
      <p>The same band runs fully on-chain on Uniswap v4 and 1inch Aqua. On v4 it runs inside every swap; a keeper is optional and only keeps the positions current between swaps.</p>`,
      `<h1>同じルールを、2つの場所で</h1>
      <p>同じbandが、Uniswap v4と1inch Aquaの上ですべてオンチェーンで動く。v4ではswapのたびに動き、keeperは任意（swapがない間もポジションを最新に保つだけ）。</p>`),
    visual: `<div class="two">
        <div class="dark"><h3>Uniswap v4 hook</h3><ul>
          <li>${t("Holds the LP's funds as two positions", "LPの資金を2つのポジションで持つ")}</li>
          <li>${t("<code>beforeSwap</code>: check the band, re-place", "<code>beforeSwap</code>でbandを確認し置き直す")}</li></ul></div>
        <div class="dark"><h3>1inch Aqua</h3><ul>
          <li>${t("One SwapVM <code>Extruction</code> prices every quote", "SwapVMの<code>Extruction</code>1つで見積もる")}</li>
          <li>${t("Funds stay in the maker's wallet", "資金はmakerのウォレットのまま")}</li>
          <li>${t("Re-placing costs no gas", "置き直しにガス代がかからない")}</li></ul></div>
      </div>`,
  },
  {
    tab: t("Backtest", "バックテスト"),
    copy: t(`<h1>Tested on real swaps</h1>
      <p>NEAR, PONS, BaseCat and LIT swaps replayed with fees and gas. Holster beat the re-centering LP on all four data sets.</p>`,
      `<h1>実際のswapで検証</h1>
      <p>NEAR・PONS・BaseCat・LITのswapを、手数料とガス代込みで再生。Holsterは4つとも、張り直すLPを上回った。</p>`),
    visual: `<table class="res">
        <tr><th></th><th>NEAR 30d</th><th>PONS 16d</th><th>BaseCat 30d</th><th>LIT 30d</th></tr>
        <tr class="hl"><td>Holster <span class="ver">v4 hook</span></td><td class="best">+71.0%</td><td>+4.6%</td><td class="best">+75.3%</td><td>+24.5%</td></tr>
        <tr><td>${t("Re-centering LP", "張り直すLP")} <span class="ver">v3</span></td><td>+0.6%</td><td>−5.4%</td><td>+56.5%</td><td>−34.7%</td></tr>
        <tr><td>${t("Fixed ranges (hindsight)", "固定レンジ（後出し）")} <span class="ver">v3</span></td><td>+51.6%</td><td class="best">+13.5%</td><td>+67.3%</td><td class="best">+26.9%</td></tr>
        <tr><td>${t("Full range", "全価格帯")} <span class="ver">v2</span></td><td>+67.2%</td><td>+0.3%</td><td>+14.6%</td><td>+21.2%</td></tr>
      </table>
      <ul class="muted small notes">
        <li>${t("<b>Holster</b>: band ±5%, 75% deployed, width ±5% (NEAR) / ±10% (others).", "<b>Holster</b>: band ±5%、出す割合75%、幅±5%（NEAR）/±10%（ほか）。")}</li>
        <li>${t("<b>Re-centering LP</b>: one range of the same width around the price, re-placed each time the price leaves it.", "<b>張り直すLP</b>: 価格の周りに同じ幅の範囲を1本置き、外れるたびに置き直す。")}</li>
        <li>${t("<b>Fixed ranges</b>: the period's lowest-to-highest price split into 4 price bands, one position each, never moved. Needs the range in advance.", "<b>固定レンジ</b>: 期間中の最安値〜最高値を4つの価格帯に分け、それぞれに1本ずつ置いて動かさない。値幅を前もって知っている前提。")}</li>
        <li>${t("<span class=\"best\">Red</span>: best in each column.", "<span class=\"best\">赤字</span>: 各列で最も良い成績。")}</li>
      </ul>
      <img src="./assets/near-pnl.svg" alt="NEAR P&L" style="margin-top:14px" />
      <p class="muted small">${t("Example: P&L over time on NEAR 30d.", "例: NEAR 30日の損益の推移。")}</p>`,
  },
  {
    tab: t("Live demo", "ライブデモ"),
    copy: t(`<h1>Live on Base Sepolia</h1>
      <p>Pump the price on the live page and watch the bid switch off. If the price stays, the TWAP catches up in about 20 minutes and the bid returns.</p>
      <p><button class="primary" onclick="location.hash='#live'">Open the live demo →</button></p>`,
      `<h1>Base Sepoliaで稼働中</h1>
      <p>「Base Sepoliaで動かす」で価格を買い上げると、買い側が止まる。価格がそのままなら、20分ほどでTWAPが追いつき、買い側が戻る。</p>
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
      <p>These need more work before production.</p>`,
      `<h1>今後の課題</h1>
      <p>実用の前に、詰めるべき点がある。</p>`),
    visual: `<div class="flow">
        <div class="box"><div class="who">${t("Other LPs", "他のLP")}</div>${t("While a side is stopped, other LPs take those trades. If most of a pool used Holster, results could change.",
          "片側を止めている間の取引は他のLPが受ける。プールの多くがHolsterになると、結果は変わりうる。")}</div>
        <div class="box"><div class="who">${t("Fixed ranges sometimes win", "固定レンジの方が良い場合")}</div>${t("To be honest, as we added backtests, several fixed concentrated ranges sometimes did better (PONS, LIT). Holster misses fee income while a side is stopped, and locks in losses each time it re-places in a ranging market. So combining Holster with fixed ranges is the next thing to test.",
          "正直に言うと、バックテストを増やしてみると、固定の集中流動性を何本も置いた方が良い結果になるケースもあった（PONS、LIT）。Holsterは片側を止めている間の手数料収入を逃し、往復する相場では置き直すたびに損が確定する。なので、固定レンジと組み合わせる形を次に試したい。")}</div>
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
