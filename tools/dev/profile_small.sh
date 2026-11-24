#!/bin/sh
# profile_small.sh -- the publication rules of profile_step.js --check over
# streams in small pieces (make profile-check): pieces of 1..64 bytes --
# frames that need padding, a datagram that is whole in the first 64 bytes,
# and one that just is not, the short path of GUDP509B -- at the minimum
# budget, 500, 732 (the short path of GUDP509B just on), 812 (2000 us) and
# 1218 units (3000 us, the STEP limit since 2026-11-22), then in the real
# time of the board at 2000 and 3000 us (no STEP over its budget).
# PIECES / BUDGETS / REAL (environment) replace the lists: the SprinterESP
# builds run the budgets of their fat STEP only (732: just on, 812, 1218).
# Usage: tools/dev/profile_small.sh dll...
dir=$(dirname "$0")
log=build/profile-small.log
pieces=${PIECES:-1 16 22 23 40 64 88}
budgets=${BUDGETS:-min 500 732 812 1218}
for piece in $pieces; do
  total=$((piece * 24))
  for budget in $budgets; do
    if ! node "$dir/profile_step.js" "$@" --check --budget "$budget" --piece "$piece" --total "$total" > "$log" 2>&1; then
      grep -E "^==|FAIL|over [1-9]|problems" "$log"
      echo "profile-check: pieces of $piece bytes at $budget units"
      exit 1
    fi
  done
done
echo "profile-check: small pieces, unit rules held"
for real in ${REAL:-2000 3000}; do
  for piece in ${PIECES:-1 16 22 23 64 88}; do
    total=$((piece * 24))
    if ! node "$dir/profile_step.js" "$@" --check --real --budget "$real" --piece "$piece" --total "$total" > "$log" 2>&1; then
      grep -E "^==|over [1-9]|problems" "$log"
      echo "profile-check: pieces of $piece bytes in real time at $real us"
      exit 1
    fi
  done
done
echo "profile-check: small pieces, no STEP over its real budget (${REAL:-2000 3000} us)"
