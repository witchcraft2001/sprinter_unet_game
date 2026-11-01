#!/bin/sh
# items_max.sh -- worst real time of every budget item over the given builds
# (profile_step.js --items at DT 2/10/20), one line per item.
# Usage: tools/dev/items_max.sh [dll...] [-- profile_step options]
node "$(dirname "$0")/profile_step.js" --items "$@" 2>&1 | grep -E " res " |
  awk '{k=$1; if (!(k in mx) || $5+0 > mx[k]+0) {mx[k]=$5; rs[k]=$3}} END {for (k in mx) printf "%-36s res %4s max %7s\n", k, rs[k], mx[k]}' | sort
