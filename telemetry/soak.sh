#!/usr/bin/env bash
# Steady telemetry for dashboards and monitors: waves of two containers (container/run.sh) for
# MINUTES (default 60), rotating decks and stakes, with a chaos fault or a known-issue scenario
# every few waves. Each wave plays new seeds (W<wave>...). A failing wave does not stop the soak:
# chaos and scenarios are supposed to trip the checks.
#   telemetry/soak.sh [MINUTES]
cd "$(dirname "$0")" || exit 1
end=$(( $(date +%s) + ${1:-60} * 60 ))
decks=(RED BLUE YELLOW GREEN BLACK MAGIC PLASMA ABANDONED)
stakes=(WHITE WHITE RED GREEN)
# shellcheck disable=SC2054 # commas belong to the specs (chaos lists)
extras=(RED:WHITE:1:jank,slow_joker RED:WHITE:1::mouth RED:WHITE:2:leak RED:WHITE:1:mod_error
        RED:WHITE:1::retrigger RED:WHITE:1:score_bug RED:WHITE:1:crash RED:WHITE:1::perkeo)
wave=0
while [ "$(date +%s)" -lt "$end" ]; do
  wave=$((wave + 1))
  a="${decks[$((wave % 8))]}:${stakes[$((wave % 4))]}:2"
  b="${decks[$(((wave + 3) % 8))]}:${stakes[$(((wave + 1) % 4))]}:2"
  [ $((wave % 3)) = 0 ] && b=${extras[$(((wave / 3 - 1) % 8))]}
  echo "== $(date +%T) wave $wave: $a $b"
  t0=$(date +%s)
  SEED_PREFIX="W$wave" container/run.sh "$a" "$b" 2>&1 | grep -E "^(container|PROBLEM|consistency)|rror|not running" || true
  [ $(( $(date +%s) - t0 )) -lt 30 ] && { echo "wave $wave ended in under 30 s, stopping: the runner is broken"; exit 1; }
done
echo "== $(date +%T) soak done after $wave waves"
