// Copies deployed addresses from contracts/deployments/v4-<chainId>.json into frontend/config.js.
//   node frontend/sync-config.mjs [chainId]
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const chainIds = process.argv[2] ? [process.argv[2]] : ["84532", "31337"];
const configPath = join(here, "config.js");
let config = readFileSync(configPath, "utf8");

for (const id of chainIds) {
  const file = join(here, "..", "contracts", "deployments", `v4-${id}.json`);
  if (!existsSync(file)) continue;
  const d = JSON.parse(readFileSync(file, "utf8"));
  const block = new RegExp(`(${id}: \\{[\\s\\S]*?)hook: "[^"]*",\\s*router: "[^"]*",\\s*base: "[^"]*",\\s*quote: "[^"]*",`);
  config = config.replace(
    block,
    `$1hook: "${d.hook}",\n    router: "${d.router}",\n    base: "${d.base}",\n    quote: "${d.quote}",`,
  );
  console.log(`chain ${id}: hook ${d.hook}`);
}

// Aqua strategy: rewrite the `aqua: { ... }` block of each chain from contracts/deployments/aqua-<chainId>.json.
for (const id of chainIds) {
  const file = join(here, "..", "contracts", "deployments", `aqua-${id}.json`);
  if (!existsSync(file)) continue;
  const d = JSON.parse(readFileSync(file, "utf8"));
  for (const k of ["aqua", "router", "holster", "base", "quote", "orderHash", "order"]) {
    const re = new RegExp(`(${id}: \\{[\\s\\S]*?aqua: \\{[\\s\\S]*?${k}: )"[^"]*"`);
    config = config.replace(re, `$1"${d[k]}"`);
  }
  console.log(`chain ${id}: aqua strategy ${d.holster}`);
}
writeFileSync(configPath, config);
