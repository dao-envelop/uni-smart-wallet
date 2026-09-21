#!/usr/bin/env node
// probe_deployment.mjs — does the stack on each chain still match `master`? (task_049)
//
// For every `deployments/<chainId>.json` and every component it names, read the runtime at the
// recorded address (`eth_getCode`) and check that each external selector of the CURRENT build
// (`out/<Contract>.sol/<Contract>.json` → `methodIdentifiers`) occurs in it. A selector solc
// dispatches on is a PUSH4 immediate in the runtime, so `63<selector>` is the needle.
//
// Selectors rather than bytecode on purpose: a byte-exact comparison needs a reproducible build
// (same solc, same settings, same metadata), and a stack that fell behind is caught either way —
// the v2.0.0 runtime lived 47 days past task_042/043 and every one of their functions was simply
// absent from it. Nothing here proves the deployed code EQUALS master; it proves master has not
// grown a function the chain does not have.
//
// Zero dependencies: JSON-RPC over fetch (node ≥ 18). Run after `forge build`:
//
//   node script/probe/probe_deployment.mjs            # all chains in deployments/
//   node script/probe/probe_deployment.mjs 42161 8453 # a subset
//   RPC_42161=https://… node script/probe/probe_deployment.mjs
//
// Exit codes: 0 — every deployed component carries every selector of master; 1 — at least one
// deployed component lacks selectors (the stack is behind); 2 — an RPC or artefact could not be
// read (the answer is unknown, not "fine"). A component master builds but no file records (e.g.
// `openImpl` before its first deploy) is reported as `not deployed` and does not fail the run:
// whether to deploy it is the owner's decision, this only makes the absence visible.

import { readFileSync, readdirSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = process.env.REPO ?? join(HERE, "..", "..");
const OUT = process.env.FORGE_OUT ?? join(REPO, "out");

const DEFAULT_RPC = {
  1: "https://ethereum-rpc.publicnode.com",
  130: "https://mainnet.unichain.org",
  1301: "https://sepolia.unichain.org",
  8453: "https://mainnet.base.org",
  42161: "https://arb1.arbitrum.io/rpc",
};

// deployments/<chainId>.json key → compiled contract whose selectors it must carry.
const COMPONENTS = {
  impl: "StableLPManager",
  volatileImpl: "VolatileLPManager",
  openImpl: "OpenVolatileLPManager",
  lens: "UniLens",
  factory: "LPManagerFactory",
  oracle: "ChainlinkPriceOracle",
  feeRedeemer: "FeeRedeemer",
  descriptor: "WalletPositionDescriptor",
};

const rpcOf = (id) => process.env[`RPC_${id}`] ?? DEFAULT_RPC[id];

function selectorsOf(contract) {
  const path = join(OUT, `${contract}.sol`, `${contract}.json`);
  if (!existsSync(path)) throw new Error(`no artefact ${path} — run \`forge build\` first`);
  const ids = JSON.parse(readFileSync(path, "utf8")).methodIdentifiers ?? {};
  return Object.entries(ids).map(([sig, sel]) => ({ sig, sel: sel.toLowerCase() }));
}

async function getCode(rpc, address) {
  const res = await fetch(rpc, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_getCode", params: [address, "latest"] }),
    signal: AbortSignal.timeout(20_000),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const body = await res.json();
  if (body.error) throw new Error(`rpc ${body.error.code}: ${body.error.message}`);
  if (typeof body.result !== "string") throw new Error("no result");
  return body.result.toLowerCase();
}

// PUSH4 of the selector. A selector with leading zero bytes may be pushed shorter by the optimizer
// (PUSH3 `62…`, PUSH2 `61…`), so those forms are accepted too.
function carries(code, sel) {
  if (code.includes(`63${sel}`)) return true;
  const stripped = sel.replace(/^(00)+/, "");
  if (stripped.length === sel.length) return false;
  const push = (0x60 + stripped.length / 2 - 1).toString(16);
  return code.includes(`${push}${stripped}`);
}

const wanted = process.argv.slice(2).map(Number);
const chains = readdirSync(join(REPO, "deployments"))
  .filter((f) => /^\d+\.json$/.test(f))
  .map((f) => Number(f.replace(".json", "")))
  .filter((id) => wanted.length === 0 || wanted.includes(id))
  .sort((a, b) => a - b);

let behind = 0;
let unknown = 0;
for (const chainId of chains) {
  const file = JSON.parse(readFileSync(join(REPO, "deployments", `${chainId}.json`), "utf8"));
  const rpc = rpcOf(chainId);
  const tag = file.tag ? ` ${file.tag}` : "";
  const commit = file.commit ? ` @${String(file.commit).slice(0, 7)}` : " (no provenance)";
  console.log(`chain ${chainId} ${file.name ?? ""}${tag}${commit}`);
  if (!rpc) {
    console.log(`  no RPC for chain ${chainId} — set RPC_${chainId}`);
    unknown++;
    continue;
  }
  for (const [key, contract] of Object.entries(COMPONENTS)) {
    let selectors;
    try {
      selectors = selectorsOf(contract);
    } catch (e) {
      console.log(`  ${contract.padEnd(24)} ${e.message}`);
      unknown++;
      continue;
    }
    const address = file[key];
    if (!address) {
      console.log(`  ${contract.padEnd(24)} not deployed (no \`${key}\` in deployments/${chainId}.json)`);
      continue;
    }
    let code;
    try {
      code = await getCode(rpc, address);
    } catch (e) {
      console.log(`  ${contract.padEnd(24)} ${address} eth_getCode failed: ${e.message}`);
      unknown++;
      continue;
    }
    if (code === "0x") {
      console.log(`  ${contract.padEnd(24)} ${address} NO CODE`);
      behind++;
      continue;
    }
    const missing = selectors.filter(({ sel }) => !carries(code, sel)).map(({ sig }) => sig);
    if (missing.length === 0) {
      console.log(`  ${contract.padEnd(24)} ${address} ok (${selectors.length} selectors)`);
    } else {
      console.log(`  ${contract.padEnd(24)} ${address} missing: ${missing.join(", ")}`);
      behind++;
    }
  }
}

if (unknown > 0) {
  console.log(`\n${unknown} component(s) could not be checked.`);
}
if (behind > 0) {
  console.log(`\n${behind} deployed component(s) lack selectors master has — the stack is behind.`);
  process.exit(1);
}
if (unknown > 0) process.exit(2);
console.log("\nEvery deployed component carries every selector of the current build.");
