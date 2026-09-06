#!/usr/bin/env python3
"""Exact-rational reference for ChainlinkPriceOracle._checkSpot.

Deliberately NOT a transcription of the Solidity expression: it works in exact
integer / Fraction arithmetic on the *definitions*

    poolPrice = (sqrtP^2 / 2^192) * 10^td0 / 10^td1      (currency1 per currency0, human units)
    refPrice  = (a0 / 10^fd0) / (a1 / 10^fd1)            (usd0 / usd1)

so any rounding or scaling error in the on-chain formula shows up as a disagreement.

Usage:
  spot_exact.py ideal <td0> <td1> <fd0> <fd1> <a0> <a1>
      -> 32-byte hex of the sqrtPriceX96 whose exact price equals refPrice (floor of isqrt),
         clamped into [MIN_SQRT_PRICE, MAX_SQRT_PRICE-1].
  spot_exact.py dev <td0> <td1> <fd0> <fd1> <a0> <a1> <sqrtP,sqrtP,...>
      -> N*32-byte hex of |pool-ref|/ref * 1e4 * 1e18, floored (deviation in bps scaled by 1e18),
         capped at 2^255.
"""
import math
import sys
from fractions import Fraction

Q192 = 1 << 192
MIN_SQRT = 4295128739
MAX_SQRT = 1461446703485210103287273052203988822378723970342
CAP = 1 << 255


def word(x):
    return "%064x" % (x & ((1 << 256) - 1))


def main():
    mode = sys.argv[1]
    td0, td1, fd0, fd1 = (int(x) for x in sys.argv[2:6])
    a0, a1 = int(sys.argv[6]), int(sys.argv[7])

    # ref = (a0 / 10^fd0) / (a1 / 10^fd1)  -- USD price of c0 expressed in c1
    ref = Fraction(a0 * 10**fd1, a1 * 10**fd0)

    if mode == "ideal":
        # raw price (currency1 base units per currency0 base unit) = ref * 10^td1 / 10^td0
        raw = ref * Fraction(10**td1, 10**td0)
        s = math.isqrt((raw.numerator * Q192) // raw.denominator)
        s = max(MIN_SQRT, min(MAX_SQRT - 1, s))
        sys.stdout.write("0x" + word(s))
        return

    if mode == "dev":
        out = []
        for tok in sys.argv[8].split(","):
            sqrtP = int(tok)
            pool = Fraction(sqrtP * sqrtP * 10**td0, Q192 * 10**td1)
            d = abs(pool - ref) / ref * 10000 * 10**18
            out.append(min(d.numerator // d.denominator, CAP))
        sys.stdout.write("0x" + "".join(word(v) for v in out))
        return

    raise SystemExit("bad mode")


main()
