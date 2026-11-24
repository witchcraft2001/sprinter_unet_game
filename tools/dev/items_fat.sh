#!/bin/sh
# items_fat.sh -- the items of the fat STEP of the SprinterESP builds
# (reserved against the worst real time, units) over streams in pieces of
# several sizes at STEP periods 2/10/20 ms and the budget 812 units, and
# the needed base reserve of each run: what COST_F* / COST_LEAN_* /
# COST_SENDCMD / PROF_FAT_DEC_US are set from (cost rule: CLAUDE.md).
# Usage: tools/dev/items_fat.sh [budget] [dll...]
dir=$(dirname "$0")
budget=${1:-812}
[ $# -gt 0 ] && shift
[ $# -eq 0 ] && set -- gudpesp gtcpesp
for piece in 1 16 40 64 300 512; do
  total=$((piece * 30)); [ "$total" -gt 8192 ] && total=8192; [ "$total" -lt 480 ] && total=480
  node "$dir/profile_step.js" "$@" --budget "$budget" --items --piece "$piece" --total "$total" 2>&1 |
    awk -v p="$piece" '/^==/ { d = $2 } /DT/ { sub(/, ratio<1.*/, ""); print "#", d, p, $0 }
      / res / { k = d " " $1; if (!(k in mx) || $5 + 0 > mx[k]) mx[k] = $5 + 0; rs[k] = $3 }
      END { for (k in mx) print "ITEM", p, k, rs[k], mx[k] }'
done | awk '$1 == "#" { print; next } { k = $3 " " $4; if (!(k in mx) || $6 > mx[k]) mx[k] = $6; rs[k] = $5 }
  END { for (k in mx) printf "%-34s res %4d  worst %6.1f  ratio %.2f  rule %d\n", k, rs[k], mx[k], rs[k] / (mx[k] ? mx[k] : 1), (mx[k] * 1.1 > mx[k] + 15 ? mx[k] * 1.1 : mx[k] + 15) + 0.999 }' | sort
