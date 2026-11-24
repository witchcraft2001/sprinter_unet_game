#!/bin/sh
# items_small.sh -- worst real time (units) of every budget item over the
# short-path stream: pieces of 1..64 bytes at the largest budget, STEP
# periods 2/10/20 ms.  One line per item and reserve.
# Usage: tools/dev/items_small.sh [dll...]
D="${*:-gudp509b gudprtl gtcp509b gtcprtl}"
for pc in 1 8 16 17 18 22 23 40 41 64; do
  node "$(dirname "$0")/profile_step.js" $D --budget ${ITEMS_BUDGET:-812} --piece $pc --total $((pc * 24)) --items 2>&1 | grep -E " res " | sed "s/^/$pc /"
done | awk '{k=$2; if (!(k in mx) || $6+0 > mx[k]+0) {mx[k]=$6; rs[k]=$4; pc[k]=$1}} END {for (k in mx) printf "%-36s res %4s max %7s  (piece %s)\n", k, rs[k], mx[k], pc[k]}' | sort
