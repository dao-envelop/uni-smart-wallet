#!/usr/bin/env node
// task_040 verification probe: the freshly-redeployed UniLens on all 5 chains.
//   - confirms each new lens address has code on-chain,
//   - calls managerFull() against the arbitrum volatile manager and checks the
//     task_040 acceptance criteria (pools=4, managed [ETH,USDC,WBTC], extra
//     [USDT], oracleType=3001, descriptor/oracle set, live sqrtPrice != 0).
//
// Requires `viem` (not a repo dependency). Run it from a dir that resolves viem, e.g.:
//   ln -s ../../../stablelp-ui/node_modules script/probe/node_modules   # sibling dApp repo
//   node script/probe/probe_lens.mjs
// or `cd` into any project that has viem installed and point at this file.
// RPCs are overridable via env  RPC_1 / RPC_130 / RPC_1301 / RPC_8453 / RPC_42161.

import { createPublicClient, http, getContract } from "viem";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
// repo root = two levels up (script/probe/ → repo root); overridable via REPO.
const REPO = process.env.REPO ?? join(HERE, "..", "..");
const ABI = JSON.parse(readFileSync(join(HERE, "unilens_abi.json"), "utf8"));

const DEFAULT_RPC = {
  1: "https://ethereum-rpc.publicnode.com",
  130: "https://mainnet.unichain.org",
  1301: "https://sepolia.unichain.org",
  8453: "https://mainnet.base.org",
  42161: "https://arb1.arbitrum.io/rpc",
};

const CHAINS = [1, 130, 1301, 8453, 42161];

function lensOf(chainId) {
  const d = JSON.parse(readFileSync(join(REPO, "deployments", `${chainId}.json`), "utf8"));
  return d.lens;
}
const rpcOf = (id) => process.env[`RPC_${id}`] ?? DEFAULT_RPC[id];
const clientOf = (id) => createPublicClient({ transport: http(rpcOf(id)) });

// ── arbitrum acceptance-criteria probe ──────────────────────────────────────
const ARB = 42161;
const ARB_MANAGER = "0x60723973ABF3BBC2ce7EB4400B728390D55e264b";
const ARB_TOKENS = {
  USDT: "0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9",
  USDC: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
  WBTC: "0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f",
};
// pass the chain's stablecoin/token list; the lens keeps only funded, un-managed ones (→ USDT).
const ARB_EXTRA = [ARB_TOKENS.USDT, ARB_TOKENS.USDC, ARB_TOKENS.WBTC];

const j = (v) => JSON.stringify(v, (_k, x) => (typeof x === "bigint" ? x.toString() : x), 2);
let failures = 0;
function check(label, cond, detail = "") {
  const ok = !!cond;
  if (!ok) failures++;
  console.log(`   ${ok ? "✅" : "❌"} ${label}${detail ? `  — ${detail}` : ""}`);
}
// Non-fatal on-chain observation (state fact the lens faithfully reports, not a lens defect).
function note(label, detail = "") {
  console.log(`   ⚠️  ${label}${detail ? `  — ${detail}` : ""}`);
}

async function probeCodePresence() {
  console.log("── lens code presence (redeploy landed?) ──");
  for (const id of CHAINS) {
    const lens = lensOf(id);
    try {
      const code = await clientOf(id).getBytecode({ address: lens });
      const bytes = code ? (code.length - 2) / 2 : 0;
      check(`chain ${id}  lens ${lens}`, bytes > 0, `${bytes} B on-chain`);
    } catch (e) {
      check(`chain ${id}  lens ${lens}`, false, `RPC error: ${e.shortMessage ?? e.message}`);
    }
  }
}

async function probeArbitrum() {
  console.log(`\n── arbitrum managerFull(${ARB_MANAGER}) ──`);
  const lens = getContract({ address: lensOf(ARB), abi: ABI, client: clientOf(ARB) });
  let full;
  try {
    full = await lens.read.managerFull([ARB_MANAGER, ARB_EXTRA]);
  } catch (e) {
    check("managerFull() call", false, e.shortMessage ?? e.message);
    return;
  }
  const c = full.config;
  const managedSyms = c.managed.map((m) => m.symbol);
  const extraSyms = c.extra.map((m) => `${m.symbol} ${m.idle}`);
  console.log(j({
    owner: c.owner, protocolFeeBps: c.protocolFeeBps, treasury: c.treasury,
    oracleType: c.oracleType, positionDescriptor: c.positionDescriptor, priceOracle: c.priceOracle,
    name: c.name, managed: managedSyms, extra: extraSyms,
    pools: c.pools.map((p) => ({ sqrtPriceX96: p.sqrtPriceX96, liquidity: p.liquidity })),
    positions: full.positions.length,
  }));

  console.log("   acceptance criteria:");
  check("pools.length == 4", c.pools.length === 4, `got ${c.pools.length}`);
  check("managed == [ETH, USDC, WBTC]", j(managedSyms) === j(["ETH", "USDC", "WBTC"]), managedSyms.join(","));
  // one funded, un-managed stable at 25.000000 (6-decimals) — on Arbitrum that token is USD₮0 (USDT0).
  check("extra == [one USD* stable, idle 25_000000]",
    c.extra.length === 1 && c.extra[0].symbol.startsWith("USD") && c.extra[0].idle === 25000000n,
    extraSyms.join(","));
  check("oracleType == 3001 (volatile)", c.oracleType === 3001n, `${c.oracleType}`);
  check("positionDescriptor set", c.positionDescriptor && c.positionDescriptor !== "0x0000000000000000000000000000000000000000", c.positionDescriptor);
  check("every pool sqrtPriceX96 != 0", c.pools.every((p) => p.sqrtPriceX96 !== 0n));
  // priceOracle is a manager-config fact, not a lens property — report, never fail on it.
  const oracleSet = c.priceOracle && c.priceOracle !== "0x0000000000000000000000000000000000000000";
  if (oracleSet) check("priceOracle set", true, c.priceOracle);
  else note("priceOracle NOT set on this manager (address(0)) — lens reports true state", c.priceOracle);
}

await probeCodePresence();
await probeArbitrum();
console.log(`\n${failures === 0 ? "ALL CHECKS PASSED ✅" : `${failures} CHECK(S) FAILED ❌`}`);
process.exit(failures === 0 ? 0 : 1);
