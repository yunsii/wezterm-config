#!/usr/bin/env bash
# Regression tests for scripts/runtime/wsl-oom-guard.sh badge classification.
#
# The badge exists because of a specific failure the guard could already see
# and nobody could: on 2026-07-26 the distro sat above the 85% high-water mark
# for four hours and then livelocked, with memory reading a survivable 88% the
# whole time while swap drained to zero. So the properties pinned here are the
# ones that make the badge worth having at all:
#
#   * silent while healthy — an always-on number is one you learn to ignore
#   * warn / crit on the memory axis
#   * warn / crit on the *swap* axis while memory still looks calm, which is
#     the exact shape of the incident that motivated this
#   * a swapless guest reads 0% swap as "no signal", not as "0% is fine"
#   * the published JSON stays parseable even when the largest process has a
#     space in its comm (Next.js reports `next-server (v1…`, which silently
#     corrupted top_rss_mib in the first cut)
#
# Runs against fixture meminfo files and a fake `ps`, so it needs no root, no
# memory pressure, and leaves the user's published status file untouched.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="$repo_root/scripts/runtime/wsl-oom-guard.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

status_file="$tmpdir/status.json"

pass=0
fail=0
it() {
  local name="$1"
  shift
  if "$@"; then
    pass=$((pass + 1))
    printf '  \xE2\x9C\x93 %s\n' "$name"
  else
    fail=$((fail + 1))
    printf '  \xE2\x9C\x97 %s\n' "$name"
  fi
}

# All values in kB, as the kernel writes them. MemTotal is held at ~1 GiB so
# the percentages in each fixture are obvious by inspection.
write_meminfo() {
  local path="$1" mem_avail="$2" swap_total="$3" swap_free="$4"
  cat >"$path" <<EOF
MemTotal:        1000000 kB
MemFree:          $mem_avail kB
MemAvailable:     $mem_avail kB
SwapTotal:       $swap_total kB
SwapFree:        $swap_free kB
EOF
}

# Returns the level the guard published for a given fixture.
level_for() {
  local mem_avail="$1" swap_total="$2" swap_free="$3"
  local meminfo="$tmpdir/meminfo"
  write_meminfo "$meminfo" "$mem_avail" "$swap_total" "$swap_free"
  rm -f "$status_file"
  WEZTERM_OOM_MEMINFO="$meminfo" \
  WEZTERM_OOM_STATUS_FILE="$status_file" \
    "$guard" sample >/dev/null 2>&1
  grep -o '"level"[[:space:]]*:[[:space:]]*"[a-z]*"' "$status_file" 2>/dev/null \
    | head -1 | grep -o '[a-z]*"$' | tr -d '"'
}

expect_level() {
  local want="$1" mem_avail="$2" swap_total="$3" swap_free="$4"
  local got
  got="$(level_for "$mem_avail" "$swap_total" "$swap_free")"
  [[ "$got" == "$want" ]] && return 0
  printf '    expected level=%s got=%s (mem_avail=%s swap %s/%s)\n' \
    "$want" "${got:-<none>}" "$mem_avail" "$swap_free" "$swap_total" >&2
  return 1
}

printf '\xE2\x96\xB8 wsl-oom-guard badge classification\n'

# 20% memory used, swap untouched.
it 'ok while both axes are low' expect_level ok 800000 1000000 1000000

# 87% / 95% used, swap untouched — the memory axis alone.
it 'warn once memory crosses the high-water mark' expect_level warn 130000 1000000 1000000
it 'crit once memory crosses the crit threshold' expect_level crit 50000 1000000 1000000

# 60% memory used — comfortably below warn — with swap at 80% / 95%. This is
# the 2026-07-26 shape: a memory-only badge stays dark right through it.
it 'warn on swap alone while memory looks calm' expect_level warn 400000 1000000 200000
it 'crit on swap alone while memory looks calm' expect_level crit 400000 1000000 50000

# A guest with swap off reports 0/0. Treating that as 0% used is correct;
# treating a missing denominator as pressure would light the bar forever.
it 'ok on a swapless guest with calm memory' expect_level ok 800000 0 0
it 'still warns on a swapless guest when memory is high' expect_level warn 130000 0 0

# --- top_comm JSON safety ------------------------------------------------
# The first cut emitted "comm rss" and split it with `read -r comm rss`, so a
# comm containing a space put half the name into the number field and produced
# invalid JSON — exactly what Next.js's `next-server (v1…` does in practice.
fake_bin="$tmpdir/bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/ps" <<'EOF'
#!/usr/bin/env bash
# Only the top-consumer query is faked; anything else falls through so the
# shim cannot silently change unrelated behavior.
case "$*" in
  *"rss,comm"*) printf '%s\n' " 2068480 next-server (v1" ;;
  *) exec /usr/bin/ps "$@" ;;
esac
EOF
chmod +x "$fake_bin/ps"

json_survives_spaced_comm() {
  local meminfo="$tmpdir/meminfo"
  write_meminfo "$meminfo" 50000 1000000 1000000
  rm -f "$status_file"
  PATH="$fake_bin:$PATH" \
  WEZTERM_OOM_MEMINFO="$meminfo" \
  WEZTERM_OOM_STATUS_FILE="$status_file" \
    "$guard" sample >/dev/null 2>&1

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$status_file" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d['top_comm'] == 'next-server (v1', d['top_comm']
assert d['top_rss_mib'] == 2020, d['top_rss_mib']
PY
    return $?
  fi
  # No python3: fall back to pinning the two fields textually.
  grep -q '"top_comm": "next-server (v1"' "$status_file" \
    && grep -q '"top_rss_mib": 2020' "$status_file"
}

it 'keeps the JSON valid when the largest comm contains a space' json_survives_spaced_comm

top_omitted_while_ok() {
  local meminfo="$tmpdir/meminfo"
  write_meminfo "$meminfo" 800000 1000000 1000000
  rm -f "$status_file"
  WEZTERM_OOM_MEMINFO="$meminfo" \
  WEZTERM_OOM_STATUS_FILE="$status_file" \
    "$guard" sample >/dev/null 2>&1
  grep -q '"top_comm": null' "$status_file"
}

# Skipping the `ps` sweep in the common case is deliberate, not incidental:
# the recorder republishes on a 30 s heartbeat and nobody reads top_comm while
# the level is ok.
it 'omits the top consumer while healthy' top_omitted_while_ok

# --- fragmentation axis --------------------------------------------------
# The third failure shape (2026-07-27): the VM died twice on
# `page allocation failure: order:7` out of vmbus_alloc_ring, with no process
# killed, no OOM record, memory at 95% and swap at a calm 38%. Neither the
# percentage badge nor earlyoom's AND gate can see it, so what is pinned here is
# that the guard reacts to *contiguity* — and that its reaction escalates in the
# right order (compact first, signal only as a last resort) and cannot fire on
# an ordinarily fragmented but healthy host.

# 11 counts = orders 0..10, as /proc/buddyinfo writes them.
write_buddyinfo() {
  local path="$1" high="$2"
  cat >"$path" <<EOF
Node 0, zone    DMA32      0      0      1      0      0      2      1      0      0      0      0
Node 0, zone   Normal   3122   6334  28440  22970  16965  11477   5967 $high $high $high $high
EOF
}

write_kmsg() {
  printf '%s\n' \
    '[    5.460347] misc dxg: dxgk: dxgkio_query_adapter_info: Ioctl failed: -2' \
    "$@" >"$tmpdir/kmsg"
}

alloc_fail_line() {
  printf '[ 9999.123456] kworker/0:1: page allocation failure: order:%s, mode:0xdc0(GFP_KERNEL|__GFP_ZERO), nodemask=(null)' "$1"
}

# Reads the two new `status` lines, which is also the operator-facing surface.
status_field() {
  local pattern="$1"
  WEZTERM_OOM_MEMINFO="$tmpdir/meminfo" \
  WEZTERM_OOM_STATUS_FILE="$status_file" \
  WEZTERM_OOM_BUDDYINFO="$tmpdir/buddyinfo" \
  WEZTERM_OOM_KMSG_FILE="$tmpdir/kmsg" \
    "$guard" status 2>/dev/null | grep -oE "$pattern" | head -1
}

frag_blocks_is() {
  local want="$1" got
  got="$(status_field 'free blocks=[0-9]+')"
  [[ "$got" == "free blocks=$want" ]] && return 0
  printf '    expected free blocks=%s got=%s\n' "$want" "${got:-<none>}" >&2
  return 1
}

alloc_fails_is() {
  local want="$1" got
  got="$(status_field '^alloc failures: [0-9]+')"
  [[ "$got" == "alloc failures: $want" ]] && return 0
  printf '    expected alloc failures=%s got=%s\n' "$want" "${got:-<none>}" >&2
  return 1
}

write_meminfo "$tmpdir/meminfo" 800000 1000000 1000000

# order>=7 summed over both zones: DMA32 contributes 0 here, Normal 4x500.
write_buddyinfo "$tmpdir/buddyinfo" 500
write_kmsg
it 'sums free blocks at and above the watched order' frag_blocks_is 2000

write_buddyinfo "$tmpdir/buddyinfo" 0
it 'reports zero when the high orders are exhausted' frag_blocks_is 0

# MAX_ORDER is not a constant across kernels (its meaning changed in 6.4), so
# the column count must come from the line, not from a hardcoded 11.
narrow_buddyinfo_still_parses() {
  printf '%s\n' 'Node 0, zone   Normal   3122   6334  28440  22970  16965  11477   5967    7    9' \
    >"$tmpdir/buddyinfo"
  frag_blocks_is 16   # orders 7 and 8 only: 7 + 9
}
it 'derives the top order from the line width, not a fixed column count' \
  narrow_buddyinfo_still_parses

# order 3 and below is a different failure with a different owner: there the
# kernel reclaims, OOM-kills and retries. Only >= 4 fails outright.
counts_only_costly_orders() {
  write_kmsg "$(alloc_fail_line 3)" "$(alloc_fail_line 7)" "$(alloc_fail_line 12)"
  alloc_fails_is 2
}
it 'counts only allocation failures above PAGE_ALLOC_COSTLY_ORDER' counts_only_costly_orders

json_carries_frag_fields() {
  write_buddyinfo "$tmpdir/buddyinfo" 500
  write_kmsg "$(alloc_fail_line 7)"
  rm -f "$status_file"
  WEZTERM_OOM_MEMINFO="$tmpdir/meminfo" \
  WEZTERM_OOM_STATUS_FILE="$status_file" \
  WEZTERM_OOM_BUDDYINFO="$tmpdir/buddyinfo" \
  WEZTERM_OOM_KMSG_FILE="$tmpdir/kmsg" \
    "$guard" sample >/dev/null 2>&1
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$status_file" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d['frag_order'] == 7, d['frag_order']
assert d['frag_free_blocks'] == 2000, d['frag_free_blocks']
assert d['alloc_failures'] == 1, d['alloc_failures']
# The badge contract is unchanged — level still comes from the two percentage
# axes only, so the Lua consumer needs no update to keep working.
assert d['level'] == 'ok', d['level']
PY
    return $?
  fi
  grep -q '"frag_free_blocks": 2000' "$status_file" \
    && grep -q '"alloc_failures": 1' "$status_file"
}
it 'publishes the fragmentation fields without changing the badge level' json_carries_frag_fields

json_carries_loadavg_fields() {
  # Loadavg enrichment rides the same sample publish as the badge; latency
  # slow-event rows on the WezTerm side read these fields from status.json.
  write_buddyinfo "$tmpdir/buddyinfo" 500
  write_kmsg
  rm -f "$status_file"
  WEZTERM_OOM_MEMINFO="$tmpdir/meminfo" \
  WEZTERM_OOM_STATUS_FILE="$status_file" \
  WEZTERM_OOM_BUDDYINFO="$tmpdir/buddyinfo" \
  WEZTERM_OOM_KMSG_FILE="$tmpdir/kmsg" \
    "$guard" sample >/dev/null 2>&1
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$status_file" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for key in ('loadavg_1', 'loadavg_5', 'loadavg_15', 'proc_runnable', 'proc_total'):
  assert key in d, key
  assert isinstance(d[key], (int, float)), (key, type(d[key]), d[key])
assert d['proc_total'] >= d['proc_runnable'] >= 0
PY
    return $?
  fi
  grep -q '"loadavg_1":' "$status_file" && grep -q '"proc_total":' "$status_file"
}
it 'publishes loadavg fields for latency slow-event enrichment' json_carries_loadavg_fields

# --- relief, driven through the real watch loop ---------------------------
fake_ps_rows="$tmpdir/ps_rows"
cat >"$fake_bin/ps" <<'EOF'
#!/usr/bin/env bash
# Both column layouts the guard asks for are served from one fixture file so a
# test only has to describe the process table once. Anything else falls through.
case "$*" in
  *"pid,rss,comm"*) cat "$FAKE_PS_ROWS" ;;
  *"rss,comm"*)     awk '{ $1 = ""; sub(/^ +/, ""); print }' "$FAKE_PS_ROWS" ;;
  *) exec /usr/bin/ps "$@" ;;
esac
EOF
chmod +x "$fake_bin/ps"

# Runs the watch loop for a few ticks against fixtures only. Every path that
# could touch real state is redirected: badge file, guard log, cgroup scope,
# buddyinfo, kernel log, compaction trigger — and renormalize is off, so no real
# process's oom_score_adj is ever rewritten by the suite.
run_watch() {
  local seconds="$1"
  shift
  PATH="$fake_bin:$PATH" \
  FAKE_PS_ROWS="$fake_ps_rows" \
  timeout -s KILL "$seconds" env \
    WEZTERM_OOM_MEMINFO="$tmpdir/meminfo" \
    WEZTERM_OOM_STATUS_FILE="$status_file" \
    WEZTERM_OOM_GUARD_LOG="$tmpdir/guard.log" \
    WEZTERM_OOM_SCOPE="$tmpdir/scope" \
    WEZTERM_OOM_RENORMALIZE=0 \
    WEZTERM_OOM_PROTECT_TMUX=0 \
    WEZTERM_OOM_WATCH_INTERVAL=1 \
    WEZTERM_OOM_BUDDYINFO="$tmpdir/buddyinfo" \
    WEZTERM_OOM_KMSG_FILE="$tmpdir/kmsg" \
    WEZTERM_OOM_COMPACT_FILE="$tmpdir/compact" \
    "$@" \
    "$guard" watch 2>&1
  return 0   # timeout always ends this; its exit status carries no information
}

# A real process to aim at, so "the guard signalled the victim" is observed
# rather than parsed out of a log line.
#
# stdout and stderr go to /dev/null, and that is load-bearing rather than tidy:
# a background child inherits the pipe of the `out="$(run_watch …)"` command
# substitution and holds it open, so the substitution would block on this
# `sleep` long after the watch loop had been killed. Every helper backgrounded
# in this section needs the same treatment.
spawn_victim() {
  sleep 300 >/dev/null 2>&1 &
  printf '%s\n' "$!"
}

victim_rows() {
  local pid="$1" comm="$2"
  printf ' %s 8388608 %s\n' "$pid" "$comm" >"$fake_ps_rows"
}

terms_the_largest_consumer() {
  local victim out
  victim="$(spawn_victim)"
  victim_rows "$victim" 'next-server (v1'
  write_buddyinfo "$tmpdir/buddyinfo" 0     # compaction will not help
  write_kmsg
  write_meminfo "$tmpdir/meminfo" 50000 1000000 1000000   # 95% used, past the gate
  rm -f "$tmpdir/compact"
  out="$(run_watch 4)"
  # Give the signal a moment to land before asking whether it did.
  sleep 0.3
  local alive=0
  kill -0 "$victim" 2>/dev/null && alive=1
  kill -KILL "$victim" 2>/dev/null
  wait "$victim" 2>/dev/null
  if (( alive == 1 )); then
    printf '    victim %s survived; log said:\n%s\n' "$victim" "$out" >&2
    return 1
  fi
  grep -q 'frag: high-order-exhaustion' <<<"$out" \
    && grep -q "frag: sent SIGTERM to pid=$victim" <<<"$out" && return 0
  printf '    missing expected log lines:\n%s\n' "$out" >&2
  return 1
}
it 'signals the largest consumer when compaction cannot free a block' \
  terms_the_largest_consumer

# The predictive trigger must stay ANDed with memory pressure. High-order
# exhaustion alone is the steady state of any long-lived Linux box; acting on it
# would mean compacting and killing on a healthy host.
quiet_when_memory_is_calm() {
  local victim out
  victim="$(spawn_victim)"
  victim_rows "$victim" 'next-server (v1'
  write_buddyinfo "$tmpdir/buddyinfo" 0
  write_kmsg
  write_meminfo "$tmpdir/meminfo" 800000 1000000 1000000   # 20% used
  out="$(run_watch 3)"
  local alive=0
  kill -0 "$victim" 2>/dev/null && alive=1
  kill -KILL "$victim" 2>/dev/null
  wait "$victim" 2>/dev/null
  (( alive == 1 )) || { printf '    victim was killed on a calm host:\n%s\n' "$out" >&2; return 1; }
  grep -q 'frag:' <<<"$out" && { printf '    acted anyway:\n%s\n' "$out" >&2; return 1; }
  return 0
}
it 'stays quiet when the high orders are empty but memory is calm' quiet_when_memory_is_calm

# A confirmed allocation failure is evidence on its own and must not wait for
# the memory gate: on 2026-07-27 one appeared 50 minutes before the reboot.
acts_on_confirmed_failure_regardless_of_memory() {
  local victim out
  victim="$(spawn_victim)"
  victim_rows "$victim" 'next-server (v1'
  write_buddyinfo "$tmpdir/buddyinfo" 500   # contiguity looks fine
  write_kmsg                                # ...and the baseline is clean
  write_meminfo "$tmpdir/meminfo" 800000 1000000 1000000   # ...and memory is calm
  # The failure arrives *after* the loop has taken its baseline, which is the
  # only thing that counts as new.
  ( sleep 2; alloc_fail_line 7 >>"$tmpdir/kmsg" ) >/dev/null 2>&1 &
  out="$(run_watch 5)"
  wait
  kill -KILL "$victim" 2>/dev/null
  wait "$victim" 2>/dev/null
  grep -q 'frag: alloc-failure' <<<"$out" && return 0
  printf '    did not react to a new allocation failure:\n%s\n' "$out" >&2
  return 1
}
it 'acts on a new allocation failure even while both percentages look fine' \
  acts_on_confirmed_failure_regardless_of_memory

# Compaction is the lossless step and must be given the chance to settle it.
# The FIFO is what makes this deterministic: the guard's write blocks until the
# reader below drains it, and only then does the fixture become healthy — so
# "buddyinfo improved" provably happens after "the guard asked for compaction",
# with no sleep-based guessing.
compaction_alone_spares_the_victim() {
  local victim out
  victim="$(spawn_victim)"
  victim_rows "$victim" 'next-server (v1'
  write_buddyinfo "$tmpdir/buddyinfo" 0
  write_kmsg
  write_meminfo "$tmpdir/meminfo" 50000 1000000 1000000
  rm -f "$tmpdir/compact"
  mkfifo "$tmpdir/compact"
  ( cat "$tmpdir/compact"; write_buddyinfo "$tmpdir/buddyinfo" 500 ) >/dev/null 2>&1 &
  out="$(run_watch 5)"
  wait
  rm -f "$tmpdir/compact"
  local alive=0
  kill -0 "$victim" 2>/dev/null && alive=1
  kill -KILL "$victim" 2>/dev/null
  wait "$victim" 2>/dev/null
  (( alive == 1 )) || { printf '    victim killed despite compaction working:\n%s\n' "$out" >&2; return 1; }
  grep -q 'frag: relieved by compaction' <<<"$out" && return 0
  printf '    no relief logged:\n%s\n' "$out" >&2
  return 1
}
it 'spares the victim when compaction restores a usable block' \
  compaction_alone_spares_the_victim

# Killing any of these turns a recoverable memory problem into the distro-level
# failure `protect` exists to prevent, so they are never candidates however big
# they get.
never_signals_an_avoided_comm() {
  local victim out
  victim="$(spawn_victim)"
  victim_rows "$victim" 'tmux: server'
  write_buddyinfo "$tmpdir/buddyinfo" 0
  write_kmsg
  write_meminfo "$tmpdir/meminfo" 50000 1000000 1000000
  rm -f "$tmpdir/compact"
  out="$(run_watch 4)"
  local alive=0
  kill -0 "$victim" 2>/dev/null && alive=1
  kill -KILL "$victim" 2>/dev/null
  wait "$victim" 2>/dev/null
  (( alive == 1 )) || { printf '    signalled a protected comm:\n%s\n' "$out" >&2; return 1; }
  grep -q 'no victim over' <<<"$out" && return 0
  printf '    expected a "no victim" line:\n%s\n' "$out" >&2
  return 1
}
it 'never signals a comm on the avoid list' never_signals_an_avoided_comm

# Below the floor the victim is collateral, not cause — an agent CLI at ~400 Mi
# is not why a 512 KiB allocation failed, and killing it only loses work.
never_signals_a_small_process() {
  local victim out
  victim="$(spawn_victim)"
  printf ' %s 409600 claude\n' "$victim" >"$fake_ps_rows"   # 400 MiB
  write_buddyinfo "$tmpdir/buddyinfo" 0
  write_kmsg
  write_meminfo "$tmpdir/meminfo" 50000 1000000 1000000
  rm -f "$tmpdir/compact"
  out="$(run_watch 4)"
  local alive=0
  kill -0 "$victim" 2>/dev/null && alive=1
  kill -KILL "$victim" 2>/dev/null
  wait "$victim" 2>/dev/null
  (( alive == 1 )) || { printf '    killed a process under the floor:\n%s\n' "$out" >&2; return 1; }
  grep -q 'no victim over' <<<"$out" && return 0
  printf '    expected a "no victim" line:\n%s\n' "$out" >&2
  return 1
}
it 'leaves processes under the RSS floor alone' never_signals_a_small_process

# The cooldown is what keeps a sustained shortage from turning into a killing
# spree: one relief attempt, then hold off and let it take effect.
cooldown_holds_off_repeats() {
  local victim out attempts
  victim="$(spawn_victim)"
  victim_rows "$victim" 'tmux: server'   # avoided, so the shortage persists
  write_buddyinfo "$tmpdir/buddyinfo" 0
  write_kmsg
  write_meminfo "$tmpdir/meminfo" 50000 1000000 1000000
  rm -f "$tmpdir/compact"
  out="$(run_watch 6 WEZTERM_OOM_FRAG_COOLDOWN=999)"
  kill -KILL "$victim" 2>/dev/null
  wait "$victim" 2>/dev/null
  attempts="$(grep -c 'frag: high-order-exhaustion' <<<"$out")"
  [[ "$attempts" == 1 ]] && return 0
  printf '    expected exactly 1 relief attempt in ~5 ticks, got %s\n' "$attempts" >&2
  return 1
}
it 'attempts relief once per cooldown window' cooldown_holds_off_repeats

# A process wedged in reclaim is exactly the one that never services SIGTERM,
# and it is also the one holding the memory. Asking it politely forever would
# make the airbag decorative, so a repeat offender gets SIGKILL.
spawn_stubborn_victim() {
  # `while :; do sleep 1; done` rather than one long sleep so that when SIGKILL
  # takes the shell, the orphaned child is gone within a second.
  bash -c 'trap "" TERM; while :; do sleep 1; done' >/dev/null 2>&1 &
  printf '%s\n' "$!"
}

escalates_to_sigkill_on_a_repeat_offender() {
  local victim out
  victim="$(spawn_stubborn_victim)"
  victim_rows "$victim" 'next-server (v1'
  write_buddyinfo "$tmpdir/buddyinfo" 0
  write_kmsg
  write_meminfo "$tmpdir/meminfo" 50000 1000000 1000000
  rm -f "$tmpdir/compact"
  # Cooldown short enough for a second attempt inside the run.
  out="$(run_watch 7 WEZTERM_OOM_FRAG_COOLDOWN=2)"
  sleep 0.3
  local alive=0
  kill -0 "$victim" 2>/dev/null && alive=1
  kill -KILL "$victim" 2>/dev/null
  wait "$victim" 2>/dev/null
  if (( alive == 1 )); then
    printf '    victim survived both signals:\n%s\n' "$out" >&2
    return 1
  fi
  grep -q "frag: sent SIGTERM to pid=$victim" <<<"$out" \
    && grep -q "frag: sent SIGKILL to pid=$victim" <<<"$out" && return 0
  printf '    expected SIGTERM then SIGKILL:\n%s\n' "$out" >&2
  return 1
}
it 'escalates to SIGKILL when the same victim survives the first attempt' \
  escalates_to_sigkill_on_a_repeat_offender

dry_run_only_reports() {
  local victim out
  victim="$(spawn_victim)"
  victim_rows "$victim" 'next-server (v1'
  write_buddyinfo "$tmpdir/buddyinfo" 0
  write_kmsg
  write_meminfo "$tmpdir/meminfo" 50000 1000000 1000000
  rm -f "$tmpdir/compact"
  out="$(run_watch 4 WEZTERM_OOM_DRY_RUN=1)"
  local alive=0
  kill -0 "$victim" 2>/dev/null && alive=1
  kill -KILL "$victim" 2>/dev/null
  wait "$victim" 2>/dev/null
  (( alive == 1 )) || { printf '    dry-run killed the victim:\n%s\n' "$out" >&2; return 1; }
  [[ -e "$tmpdir/compact" ]] && { printf '    dry-run triggered compaction\n' >&2; return 1; }
  grep -q 'frag: dry-run' <<<"$out" && return 0
  printf '    no dry-run line:\n%s\n' "$out" >&2
  return 1
}
it 'takes no action under dry-run but still reports' dry_run_only_reports

action_off_disables_the_axis() {
  local victim out
  victim="$(spawn_victim)"
  victim_rows "$victim" 'next-server (v1'
  write_buddyinfo "$tmpdir/buddyinfo" 0
  write_kmsg
  write_meminfo "$tmpdir/meminfo" 50000 1000000 1000000
  rm -f "$tmpdir/compact"
  out="$(run_watch 4 WEZTERM_OOM_FRAG_ACTION=off)"
  local alive=0
  kill -0 "$victim" 2>/dev/null && alive=1
  kill -KILL "$victim" 2>/dev/null
  wait "$victim" 2>/dev/null
  (( alive == 1 )) || { printf '    acted with the axis off:\n%s\n' "$out" >&2; return 1; }
  [[ -e "$tmpdir/compact" ]] && { printf '    compacted with the axis off\n' >&2; return 1; }
  # Still records the shortage: turning the action off must not blind the log.
  grep -q 'frag: high-order-exhaustion' <<<"$out" && return 0
  printf '    stopped logging too:\n%s\n' "$out" >&2
  return 1
}
it 'still records the shortage when the action is off' action_off_disables_the_axis

compact_only_never_signals() {
  local victim out
  victim="$(spawn_victim)"
  victim_rows "$victim" 'next-server (v1'
  write_buddyinfo "$tmpdir/buddyinfo" 0
  write_kmsg
  write_meminfo "$tmpdir/meminfo" 50000 1000000 1000000
  rm -f "$tmpdir/compact"
  out="$(run_watch 4 WEZTERM_OOM_FRAG_ACTION=compact)"
  local alive=0
  kill -0 "$victim" 2>/dev/null && alive=1
  kill -KILL "$victim" 2>/dev/null
  wait "$victim" 2>/dev/null
  (( alive == 1 )) || { printf '    signalled under action=compact:\n%s\n' "$out" >&2; return 1; }
  [[ -f "$tmpdir/compact" ]] || { printf '    never asked for compaction\n' >&2; return 1; }
  grep -q 'leaving the kill to earlyoom' <<<"$out" && return 0
  printf '    expected the hand-off line:\n%s\n' "$out" >&2
  return 1
}
it 'compacts but never signals under action=compact' compact_only_never_signals

printf 'wsl-oom-guard: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
