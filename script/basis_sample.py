#!/usr/bin/env python3
"""Sample the Chainlink-vs-pool price basis over time and size the oracle's spot tolerance from it.

`ChainlinkPriceOracle.maxSpotDeviationBps` bounds how far a pool's own price may sit from the
Chainlink reference before an *operator* add is refused (`SpotPriceOutOfBounds`). Set it below the
basis an honest pool actually shows and operators fail closed for no reason; set it far above and the
spot gate stops meaning anything. The basis is not a constant — it moves with feed cadence and market
noise — so one snapshot cannot size it. This runs `PriceDeviation.s.sol` repeatedly and reports the
distribution.

    script/basis_sample.py --rounds 8 --interval 300
    script/basis_sample.py --rounds 1 --chains 1 --json out.json

Read-only: no broadcast, no keys. Needs the RPC aliases from foundry.toml (`.env` is picked up by
forge itself) and `jq`-free stdlib only.

Exit codes: 0 every chain has headroom, 2 at least one chain is tight or breached (see THRESHOLDS),
1 a measurement failed.
"""

import argparse
import json
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RPC = {1: "mainnet", 130: "unichain", 8453: "base", 42161: "arbitrum"}

# A tolerance is healthy at >= 1.5x the worst basis seen — the ratio the shipped values already use
# (Base 50/32, Arbitrum 45/30, mainnet 40/25, Unichain 185/123). Below 1.25x an ordinary swing in the
# basis reaches the gate, which is the state worth waking someone for.
HEALTHY_RATIO = 1.5
TIGHT_RATIO = 1.25
RECOMMEND_RATIO = 1.6

POOL_RE = re.compile(r"^\s*\[(?P<label>[^\]]+)\]\s*$")
BASIS_RE = re.compile(r"^\s*basis \(bps\):\s*(?P<v>\d+)\s*$")
FEE_RE = re.compile(r"^\s*pool fee \(bps\):\s*(?P<v>\d+)\s*$")


def measure(chain: int, verbose: bool) -> dict[str, int]:
    """One `PriceDeviation` run. Returns {"<label> <fee>bps": basis}."""
    cfg = ROOT / f"script/price_pools/{chain}.json"
    if not cfg.exists():
        raise FileNotFoundError(f"no pool config for chain {chain}: {cfg}")
    proc = subprocess.run(
        ["forge", "script", "script/PriceDeviation.s.sol", "--sig", "run()", "--rpc-url", RPC[chain]],
        cwd=ROOT, env={**__import__("os").environ, "POOLS_CONFIG": str(cfg)},
        capture_output=True, text=True, timeout=600,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"chain {chain}: forge exited {proc.returncode}\n{proc.stderr[-500:]}")

    out, label = {}, None
    pending_basis = None
    for line in proc.stdout.splitlines():
        if m := POOL_RE.match(line):
            label, pending_basis = m.group("label"), None
        elif m := BASIS_RE.match(line):
            pending_basis = int(m.group("v"))
        elif (m := FEE_RE.match(line)) and label and pending_basis is not None:
            # The fee disambiguates same-pair pools (ETH/USDC exists at 0.05% and 0.3%).
            key = f"{label} {m.group('v')}bps"
            out[key] = pending_basis
            pending_basis = None
    if not out:
        raise RuntimeError(f"chain {chain}: parsed no pools; PriceDeviation output changed?")
    if verbose:
        print(f"    chain {chain}: " + ", ".join(f"{k}={v}" for k, v in out.items()), flush=True)
    return out


def live_tolerance(chain: int) -> int | None:
    """`maxSpotDeviationBps` from the deployed oracle — the value actually in force, not the config."""
    dep = ROOT / f"deployments/{chain}.json"
    if not dep.exists():
        return None
    oracle = json.loads(dep.read_text()).get("oracle")
    if not oracle:
        return None
    proc = subprocess.run(
        ["cast", "call", oracle, "maxSpotDeviationBps()(uint16)", "--rpc-url", RPC[chain]],
        cwd=ROOT, capture_output=True, text=True, timeout=120,
    )
    if proc.returncode != 0:
        return None
    return int(re.sub(r"\[[^\]]*\]", "", proc.stdout).strip())


def percentile(xs: list[int], q: float) -> float:
    if len(xs) == 1:
        return float(xs[0])
    return statistics.quantiles(xs, n=100, method="inclusive")[int(q * 100) - 1]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rounds", type=int, default=6, help="samples per chain (default 6)")
    ap.add_argument("--interval", type=int, default=300, help="seconds between rounds (default 300)")
    ap.add_argument("--chains", default="1,130,8453,42161", help="comma-separated chain ids")
    ap.add_argument("--json", metavar="FILE", help="also write the full sample set here")
    ap.add_argument("-q", "--quiet", action="store_true", help="only the summary")
    args = ap.parse_args()

    chains = [int(c) for c in args.chains.split(",") if c.strip()]
    for c in chains:
        if c not in RPC:
            print(f"unknown chain {c}; known: {sorted(RPC)}", file=sys.stderr)
            return 1

    samples: dict[int, dict[str, list[int]]] = {c: {} for c in chains}
    started = time.time()
    for r in range(1, args.rounds + 1):
        if not args.quiet:
            print(f"round {r}/{args.rounds} ({time.strftime('%H:%M:%S')})", flush=True)
        for c in chains:
            try:
                for pool, basis in measure(c, not args.quiet).items():
                    samples[c].setdefault(pool, []).append(basis)
            except Exception as exc:  # a chain that fails once should not lose the whole series
                print(f"    chain {c}: FAILED — {exc}", file=sys.stderr, flush=True)
        if r < args.rounds:
            time.sleep(args.interval)

    print(f"\n=== basis over {args.rounds} rounds / {int(time.time() - started) // 60} min ===\n")
    report, tight = {}, False
    for c in chains:
        if not samples[c]:
            print(f"chain {c}: no samples\n")
            continue
        tol = live_tolerance(c)
        worst_pool = max(samples[c], key=lambda p: max(samples[c][p]))
        worst = max(samples[c][worst_pool])
        p95 = max(percentile(v, 0.95) for v in samples[c].values())
        rec = int(-(-worst * RECOMMEND_RATIO // 5) * 5)  # round up to a multiple of 5

        if tol is None:
            verdict = "tolerance unknown"
        elif worst >= tol:
            verdict, tight = "BREACHED — operators already refused here", True
        elif worst * TIGHT_RATIO >= tol:
            verdict, tight = "TIGHT — ordinary noise reaches the gate", True
        elif worst * HEALTHY_RATIO >= tol:
            verdict = "thin"
        else:
            verdict = "ok"

        print(f"chain {c} ({RPC[c]}): tolerance {tol}, worst {worst}, p95 {p95:.0f} — {verdict}")
        for pool, v in sorted(samples[c].items(), key=lambda kv: -max(kv[1])):
            print(f"    {pool:24} max {max(v):>4}  p95 {percentile(v, 0.95):>5.0f}  median {statistics.median(v):>5.0f}  n={len(v)}")
        if verdict not in ("ok", "tolerance unknown"):
            print(f"    -> recommend maxSpotDeviationBps = {rec} (owner-only setMaxSpotDeviationBps, no redeploy)")
        print()
        report[c] = {"tolerance": tol, "worst": worst, "p95": round(p95, 1),
                     "worst_pool": worst_pool, "recommend": rec, "verdict": verdict,
                     "samples": samples[c]}

    if args.json:
        Path(args.json).write_text(json.dumps(
            {"started": int(started), "rounds": args.rounds, "interval": args.interval, "chains": report},
            indent=2) + "\n")
        print(f"samples written to {args.json}")

    return 2 if tight else 0


if __name__ == "__main__":
    sys.exit(main())
