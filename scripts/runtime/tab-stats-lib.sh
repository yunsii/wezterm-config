#!/usr/bin/env bash
# Per-workspace tmux-session activity statistics for the tab-visibility
# pipeline (activity-based top-N rendering). One JSON file per workspace
# under the shared `wezterm-runtime` state dir, mirrored to the cross-FS
# routing rule documented in `docs/architecture.md` (the lua tick reads
# this file on Windows; the tmux hook writes it from WSL).
#
# Schema v4 (per workspace):
#   {
#     "version": 4,
#     "half_life_days": 7,
#     "sessions": {
#       "<session_name>": {
#         "activity_score": <float — decayed git-activity score>,
#         "activity_count": <int — lifetime activity event count>,
#         "last_activity_ms": <epoch ms>,
#         "last_seen_ms":   <epoch ms>,
#         "last_git_fingerprint": <string — mirror of last written path fp>,
#         "git_fingerprints": { "<abs_cwd>": "<fp>", ... },
#         "last_access_ms": <epoch ms — stamped from access ledger>,
#         "dwell_ms":       <float — legacy focus dwell, diagnostic>,
#         "total_dwell_ms": <int — legacy lifetime dwell, diagnostic>,
#         "last_bump_ms":   <epoch ms>,
#         "raw_count":      <int — legacy focus event count>
#       }
#     }
#   }
#
# Ranking signal is `activity_score + access_bonus(last_access_ms)`, where
# access_bonus uses the same half-life as activity and weight
# TAB_STATS_ACCESS_WEIGHT. Git fingerprint changes (HEAD/index/worktree
# diff) on the configured main cwd *and* its linked worktrees add activity
# credit onto the base session; fingerprints are keyed per path so paths
# do not thrash each other. Focus/view events update last_seen/raw_count
# for diagnostics only.
#
# `total_dwell_ms` is never decayed and receives the full uncapped dwell;
# exposed to the picker / diagnostics for "lifetime time spent" display.
#
# v1 migration: detected by `version < 2` on the parent object. v1
# `weight` values are corrupted by renormalize+fragmentation (a project
# refreshed 7 times via refresh-current-window ends up with 7 small
# rows whose weights don't sum back to the original lifetime usage),
# v1 → v4 migration: so we ignore weight at migration time and seed dwell_ms from
# raw_count instead — each historical focus event grants 30s of
# credit, matching the v1 saturation point. After the first v4 write
# the file is version=4 and dwell_ms accumulates capped diagnostic credit.
#
# v2 → v4 migration: v2 stored uncapped wall-clock dwell in dwell_ms,
# which over-promoted sessions left focused overnight. On the first v4
# write, pre-existing v2 dwell_ms is clamped to raw_count * the per-burst
# credit cap. total_dwell_ms is preserved.
#
# Sourced by:
#   scripts/runtime/tab-stats-bump.sh    (writer, called from tmux hook)
#   future readers: lua tab_visibility module via direct JSON read
#                   tab-overflow picker

set -u

__TAB_STATS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$__TAB_STATS_LIB_DIR/windows-runtime-paths-lib.sh"

# Same constants exposed both as integers (jq math) and bash vars.
TAB_STATS_HALF_LIFE_DAYS=7
TAB_STATS_MS_PER_DAY=86400000
# Access-ledger contribution to sticky rank_score. Calibrated between
# index (+40) and HEAD (+100): a visit today ≈ one modest edit, and
# alone cannot outrank a fresh commit. Same half-life as activity_score.
TAB_STATS_ACCESS_WEIGHT="${TAB_STATS_ACCESS_WEIGHT:-60}"
# Skip bump if the same session was bumped within this window. Hook can
# fire several times per second when a tmux client churns; we only want
# a single weight-event per real focus burst.
TAB_STATS_THROTTLE_MS=500
# Dead zone for tab_stats_close_out: dwell shorter than this is treated
# as a path-through (Alt+x peek, accidental hover) and contributes zero
# dwell. Longer bursts pay capped ranking credit while preserving full
# wall-clock dwell in total_dwell_ms.
TAB_STATS_DWELL_DEAD_ZONE_MS=1000
# Maximum ranking credit paid by one focus burst. Full dwell still goes
# into total_dwell_ms; this only caps the top-N / picker sort signal.
TAB_STATS_DWELL_CREDIT_CAP_MS=1800000

__TAB_STATS_DIR_CACHED=""

tab_stats_dir() {
  if [[ -n "$__TAB_STATS_DIR_CACHED" ]]; then
    printf '%s' "$__TAB_STATS_DIR_CACHED"
    return 0
  fi
  if windows_runtime_detect_paths 2>/dev/null; then
    __TAB_STATS_DIR_CACHED="$WINDOWS_RUNTIME_STATE_WSL/state/tab-stats"
  else
    local state_root="${XDG_STATE_HOME:-$HOME/.local/state}/wezterm-runtime"
    __TAB_STATS_DIR_CACHED="$state_root/state/tab-stats"
  fi
  printf '%s' "$__TAB_STATS_DIR_CACHED"
}

# Per-client enter-state directory. Each tmux client tracks the session
# it most recently entered + the timestamp so the next bump (a switch
# to a different session) can close out the previous one with the
# correct dwell. Sibling of tab-stats/ under <state>/.
tab_stats_enter_dir() {
  printf '%s' "$(tab_stats_dir)/../tab-stats-enter"
}

# tmux exposes a client identity as `client_tty` (e.g. /dev/pts/3).
# Slug it into a safe filename: drop /dev/, rewrite any other
# non-alnum into _. Per-client (not per-session) because dwell
# semantics belong to the client doing the switching, not to the
# session being switched to.
tab_stats_client_slug() {
  local tty="${1:-}"
  if [[ -z "$tty" ]]; then
    printf '%s' '_unknown'
    return 0
  fi
  printf '%s' "$tty" \
    | LC_ALL=C sed -e 's|^/dev/||' -e 's|[^a-zA-Z0-9_-]|_|g'
}

# Sanitize workspace string into a safe filename (lowercase, alnum + dash
# + underscore). Workspace names like `default` / `work` / `config` pass
# through unchanged; any unexpected punctuation is rewritten to `_`.
tab_stats_workspace_slug() {
  local raw="${1:-}"
  if [[ -z "$raw" ]]; then
    printf '%s' '_unknown'
    return 0
  fi
  printf '%s' "$raw" | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C sed 's/[^a-z0-9_-]/_/g'
}

tab_stats_path() {
  local workspace="${1:?missing workspace}"
  local slug
  slug="$(tab_stats_workspace_slug "$workspace")"
  printf '%s/%s.json' "$(tab_stats_dir)" "$slug"
}

tab_stats_lock_path() {
  local workspace="${1:?missing workspace}"
  printf '%s.lock' "$(tab_stats_path "$workspace")"
}

tab_stats_now_ms() {
  date +%s%3N
}

tab_stats_init() {
  local workspace="${1:?missing workspace}"
  local path dir
  path="$(tab_stats_path "$workspace")"
  dir="${path%/*}"
  mkdir -p "$dir"
  if [[ ! -f "$path" ]]; then
    printf '%s\n' \
      "{\"version\":4,\"half_life_days\":${TAB_STATS_HALF_LIFE_DAYS},\"sessions\":{}}" \
      > "$path"
  fi
}

tab_stats_read() {
  local workspace="${1:?missing workspace}"
  local path
  path="$(tab_stats_path "$workspace")"
  if [[ -f "$path" ]]; then
    cat "$path"
  else
    printf '%s' \
      "{\"version\":4,\"half_life_days\":${TAB_STATS_HALF_LIFE_DAYS},\"sessions\":{}}"
  fi
}

# Atomic write via tmp + rename. Caller MUST hold the flock.
tab_stats_write() {
  local workspace="${1:?missing workspace}"
  local payload="$2"
  local path tmp
  path="$(tab_stats_path "$workspace")"
  tmp="${path}.tmp.$$"
  printf '%s\n' "$payload" > "$tmp"
  mv "$tmp" "$path"
}

# Single jq pipeline that:
#   1. decays every session's dwell_ms by exp(-Δt_ms / half_life_ms * ln2)
#      — for v1 entries (version < 2), seeds dwell_ms from
#        raw_count * 30000 (30s per past focus event, matching the v1
#        saturation point). raw_count is undecayed, so a heavily-used
#        project that v1 fragmented across refresh variants recovers
#        the right magnitude despite the renormalize damage to weight.
#      — for v2 entries, clamps pre-existing uncapped dwell_ms to
#        raw_count * TAB_STATS_DWELL_CREDIT_CAP_MS so stale overnight
#        dwell cannot keep a legacy row pinned above a frequently used
#        one during migration.
#   2. updates each session's last_bump_ms = now (so the next decay
#      computes age from a clean baseline — see comment in tab_stats_lib
#      header about why we reset last_bump_ms on every session, not just
#      the target)
#   2. decays every session's activity_score by the same half-life.
#   3. on the target session: legacy focus fields update only
#      (dwell_ms / total_dwell_ms / raw_count / last_seen_ms).
#      Activity ranking is updated only by tab_stats_record_activity.
#   4. emits the v4 shape — no normalize step.
#
# Both tab_stats_bump (entry: dwell_delta=0, raw_delta=1) and
# tab_stats_close_out (leave: dwell_delta=actual_dwell_ms, raw_delta=0)
# flow through this same pipeline so reads always see a freshly-decayed
# snapshot regardless of which event source wrote it.
__TAB_STATS_WRITE_JQ='
  def half_life_ms($d): ($d * 86400000);
  def decay($w; $age_ms; $half_ms):
    if $half_ms <= 0 then $w
    elif $age_ms <= 0 then $w
    else $w * pow(2; -($age_ms / $half_ms))
    end;
  def min2($a; $b): if $a < $b then $a else $b end;
  def historical_credit_count($v):
    if (($v.raw_count // 0) | tonumber) > 0 then (($v.raw_count // 0) | tonumber)
    elif ((($v.dwell_ms // 0) | tonumber) > 0) or ((($v.total_dwell_ms // 0) | tonumber) > 0) then 1
    else 0
    end;
  ($now | tonumber) as $now
  | ($session | tostring) as $session
  | ($dwell_delta | tonumber) as $dwell_delta
  | ($raw_delta | tonumber) as $raw_delta
  | ($credit_cap | tonumber) as $credit_cap
  | min2($dwell_delta; $credit_cap) as $credit_delta
  | (.half_life_days // 7) as $hld
  | half_life_ms($hld) as $half_ms
  | ((.version // 1) | tonumber) as $ver
  | (.sessions // {}) as $existing
  | ($existing
      | to_entries
      | map(
          .key as $name
          | .value as $v
          | (if $ver >= 3 then ($v.dwell_ms // 0)
             elif $ver >= 2 then min2(($v.dwell_ms // 0); (historical_credit_count($v) * $credit_cap))
             else (($v.raw_count // 0) * 30000)
             end) as $seed_dwell
          | (if $ver >= 2 then ($v.total_dwell_ms // 0)
             else (($v.raw_count // 0) * 30000)
             end) as $seed_total
          | { key: $name,
              value: ($v + {
                activity_score: decay(($v.activity_score // 0); ($now - ($v.last_activity_ms // $now)); $half_ms),
                activity_count: ($v.activity_count // 0),
                last_activity_ms: ($v.last_activity_ms // 0),
                last_seen_ms: ($v.last_seen_ms // ($v.last_bump_ms // 0)),
                last_git_fingerprint: ($v.last_git_fingerprint // ""),
                dwell_ms:       decay($seed_dwell; ($now - ($v.last_bump_ms // $now)); $half_ms),
                total_dwell_ms: $seed_total,
                last_bump_ms:   $now,
                raw_count:      ($v.raw_count // 0)
              })
            }
        )
      | from_entries
    ) as $decayed
  | ($decayed[$session] // {
      activity_score: 0,
      activity_count: 0,
      last_activity_ms: 0,
      last_seen_ms: 0,
      last_git_fingerprint: "",
      dwell_ms: 0,
      total_dwell_ms: 0,
      last_bump_ms: $now,
      raw_count: 0
    }) as $cur
  | $decayed
  | .[$session] = ($cur + {
      dwell_ms:       (($cur.dwell_ms // 0) + $credit_delta),
      total_dwell_ms: (($cur.total_dwell_ms // 0) + $dwell_delta),
      last_bump_ms:   $now,
      last_seen_ms:   $now,
      raw_count:      (($cur.raw_count // 0) + $raw_delta)
    })
  | { version: 4, half_life_days: $hld, sessions: . }
'

# Internal: apply $dwell_delta + $raw_delta to <session> under the
# workspace's lock. Callers compute the deltas; this just runs the
# pipeline atomically.
__tab_stats_write_delta() {
  local workspace="$1" session_name="$2" dwell_delta="$3" raw_delta="$4"
  local now current updated lock
  now="$(tab_stats_now_ms)"
  tab_stats_init "$workspace"
  lock="$(tab_stats_lock_path "$workspace")"
  (
    flock -x 9
    current="$(tab_stats_read "$workspace")"
    updated="$(printf '%s' "$current" \
      | jq --arg session "$session_name" --arg now "$now" \
           --arg dwell_delta "$dwell_delta" --arg raw_delta "$raw_delta" \
           --arg credit_cap "$TAB_STATS_DWELL_CREDIT_CAP_MS" \
           "$__TAB_STATS_WRITE_JQ" 2>/dev/null)"
    if [[ -z "$updated" ]]; then
      return 0
    fi
    tab_stats_write "$workspace" "$updated"
  ) 9>>"$lock"
}

# Entry signal. Increments raw_count (the lifetime "I saw this session
# take focus" counter) but contributes NO dwell on its own — the dwell
# is paid on leave by tab_stats_close_out, equal to the actual focus
# time. Returns 0 always; throttled re-fires within
# TAB_STATS_THROTTLE_MS are silently skipped.
tab_stats_bump() {
  local workspace="${1:?missing workspace}"
  local session_name="${2:?missing session_name}"
  local now last_ms current lock
  now="$(tab_stats_now_ms)"
  tab_stats_init "$workspace"
  lock="$(tab_stats_lock_path "$workspace")"
  (
    flock -x 9
    current="$(tab_stats_read "$workspace")"
    last_ms="$(printf '%s' "$current" \
      | jq -r --arg s "$session_name" \
          '.sessions[$s].last_bump_ms // 0' 2>/dev/null || echo 0)"
    if (( last_ms > 0 )) && (( now - last_ms < TAB_STATS_THROTTLE_MS )); then
      return 0
    fi
  ) 9>>"$lock"
  __tab_stats_write_delta "$workspace" "$session_name" 0 1
}

# Leave signal. Pays the dwell tab_stats_bump didn't — equal to the
# actual ms the session held focus. Sub-second glances are filtered
# (Alt+x peek that lands and immediately leaves shouldn't accrue any
# dwell), and ranking credit is capped per burst so overnight idle time
# does not dominate top-N. total_dwell_ms still receives the full dwell.
tab_stats_close_out() {
  local workspace="${1:?missing workspace}"
  local session_name="${2:?missing session_name}"
  local dwell_ms="${3:?missing dwell_ms}"
  if (( dwell_ms < TAB_STATS_DWELL_DEAD_ZONE_MS )); then
    return 0
  fi
  __tab_stats_write_delta "$workspace" "$session_name" "$dwell_ms" 0
}

# Optional $cwd_key (5th arg / --arg cwd_key):
# - non-empty → write only git_fingerprints[cwd_key] (do not touch
#   last_git_fingerprint; that legacy field must stay a main-cwd mirror
#   or first-sample of every linked path thrashes main on the next tick)
# - empty → legacy single-path write to last_git_fingerprint
__TAB_STATS_ACTIVITY_JQ='
  def half_life_ms($d): ($d * 86400000);
  def decay($w; $age_ms; $half_ms):
    if $half_ms <= 0 then $w
    elif $age_ms <= 0 then $w
    else $w * pow(2; -($age_ms / $half_ms))
    end;
  def with_path_fp($cur; $fp; $cwd_key):
    if ($cwd_key | tostring) == "" then
      ($cur + { last_git_fingerprint: $fp })
    else
      ($cur + {
        git_fingerprints: (($cur.git_fingerprints // {}) + { ($cwd_key | tostring): $fp })
      })
    end;
  ($now | tonumber) as $now
  | ($session | tostring) as $session
  | ($score_delta | tonumber) as $score_delta
  | ($fingerprint | tostring) as $fingerprint
  | ($cwd_key | tostring) as $cwd_key
  | (.half_life_days // 7) as $hld
  | half_life_ms($hld) as $half_ms
  | (.sessions // {}) as $existing
  | ($existing
      | to_entries
      | map(
          .key as $name
          | .value as $v
          | { key: $name,
              value: ($v + {
                activity_score: decay(($v.activity_score // 0); ($now - ($v.last_activity_ms // $now)); $half_ms),
                activity_count: ($v.activity_count // 0),
                last_activity_ms: ($v.last_activity_ms // 0),
                last_seen_ms: ($v.last_seen_ms // ($v.last_bump_ms // 0)),
                last_git_fingerprint: ($v.last_git_fingerprint // ""),
                dwell_ms: ($v.dwell_ms // 0),
                total_dwell_ms: ($v.total_dwell_ms // 0),
                last_bump_ms: ($v.last_bump_ms // 0),
                raw_count: ($v.raw_count // 0)
              })
            }
        )
      | from_entries
    ) as $decayed
  | ($decayed[$session] // {
      activity_score: 0,
      activity_count: 0,
      last_activity_ms: 0,
      last_seen_ms: 0,
      last_git_fingerprint: "",
      git_fingerprints: {},
      last_access_ms: 0,
      dwell_ms: 0,
      total_dwell_ms: 0,
      last_bump_ms: 0,
      raw_count: 0
    }) as $cur
  | $decayed
  | .[$session] = (with_path_fp($cur; $fingerprint; $cwd_key) + {
      activity_score: (($cur.activity_score // 0) + $score_delta),
      activity_count: (($cur.activity_count // 0) + 1),
      last_activity_ms: $now
    })
  | { version: 4, half_life_days: $hld, sessions: . }
'

tab_stats_record_activity() {
  local workspace="${1:?missing workspace}"
  local session_name="${2:?missing session_name}"
  local score_delta="${3:?missing score_delta}"
  local fingerprint="${4:?missing fingerprint}"
  local cwd_key="${5:-}"
  local now current updated lock
  now="$(tab_stats_now_ms)"
  tab_stats_init "$workspace"
  lock="$(tab_stats_lock_path "$workspace")"
  (
    flock -x 9
    current="$(tab_stats_read "$workspace")"
    updated="$(printf '%s' "$current" \
      | jq --arg session "$session_name" --arg now "$now" \
           --arg score_delta "$score_delta" --arg fingerprint "$fingerprint" \
           --arg cwd_key "$cwd_key" \
           "$__TAB_STATS_ACTIVITY_JQ" 2>/dev/null)"
    if [[ -z "$updated" ]]; then
      return 0
    fi
    tab_stats_write "$workspace" "$updated"
  ) 9>>"$lock"
}

__TAB_STATS_FINGERPRINT_JQ='
  def with_path_fp($cur; $fp; $cwd_key):
    if ($cwd_key | tostring) == "" then
      ($cur + { last_git_fingerprint: $fp })
    else
      ($cur + {
        git_fingerprints: (($cur.git_fingerprints // {}) + { ($cwd_key | tostring): $fp })
      })
    end;
  ($session | tostring) as $session
  | ($fingerprint | tostring) as $fingerprint
  | ($cwd_key | tostring) as $cwd_key
  | (.half_life_days // 7) as $hld
  | (.sessions // {}) as $existing
  | ($existing[$session] // {
      activity_score: 0,
      activity_count: 0,
      last_activity_ms: 0,
      last_seen_ms: 0,
      last_git_fingerprint: "",
      git_fingerprints: {},
      last_access_ms: 0,
      dwell_ms: 0,
      total_dwell_ms: 0,
      last_bump_ms: 0,
      raw_count: 0
    }) as $cur
  | $existing
  | .[$session] = with_path_fp($cur; $fingerprint; $cwd_key)
  | { version: 4, half_life_days: $hld, sessions: . }
'

tab_stats_set_git_fingerprint() {
  local workspace="${1:?missing workspace}"
  local session_name="${2:?missing session_name}"
  local fingerprint="${3:?missing fingerprint}"
  local cwd_key="${4:-}"
  local current updated lock
  tab_stats_init "$workspace"
  lock="$(tab_stats_lock_path "$workspace")"
  (
    flock -x 9
    current="$(tab_stats_read "$workspace")"
    updated="$(printf '%s' "$current" \
      | jq --arg session "$session_name" --arg fingerprint "$fingerprint" \
           --arg cwd_key "$cwd_key" \
           "$__TAB_STATS_FINGERPRINT_JQ" 2>/dev/null)"
    if [[ -z "$updated" ]]; then
      return 0
    fi
    tab_stats_write "$workspace" "$updated"
  ) 9>>"$lock"
}

# Stamp access-ledger last_access_ms onto a session row (no score mutate).
# Ranking computes access_bonus from this timestamp at read time.
__TAB_STATS_ACCESS_JQ='
  ($session | tostring) as $session
  | ($last_access_ms | tonumber) as $la
  | (.half_life_days // 7) as $hld
  | (.sessions // {}) as $existing
  | ($existing[$session] // {
      activity_score: 0,
      activity_count: 0,
      last_activity_ms: 0,
      last_seen_ms: 0,
      last_git_fingerprint: "",
      git_fingerprints: {},
      last_access_ms: 0,
      dwell_ms: 0,
      total_dwell_ms: 0,
      last_bump_ms: 0,
      raw_count: 0
    }) as $cur
  | $existing
  | .[$session] = ($cur + { last_access_ms: $la })
  | { version: 4, half_life_days: $hld, sessions: . }
'

tab_stats_set_last_access() {
  local workspace="${1:?missing workspace}"
  local session_name="${2:?missing session_name}"
  local last_access_ms="${3:?missing last_access_ms}"
  local current updated lock
  [[ "$last_access_ms" =~ ^[0-9]+$ ]] || return 0
  (( last_access_ms > 0 )) || return 0
  tab_stats_init "$workspace"
  lock="$(tab_stats_lock_path "$workspace")"
  (
    flock -x 9
    current="$(tab_stats_read "$workspace")"
    updated="$(printf '%s' "$current" \
      | jq --arg session "$session_name" --arg last_access_ms "$last_access_ms" \
           "$__TAB_STATS_ACCESS_JQ" 2>/dev/null)"
    if [[ -z "$updated" ]]; then
      return 0
    fi
    tab_stats_write "$workspace" "$updated"
  ) 9>>"$lock"
}

# Read the stored fingerprint for a session path.
# - cwd_key non-empty: only git_fingerprints[cwd_key] (empty if missing).
#   Do NOT fall back to last_git_fingerprint — that is the main-cwd
#   legacy mirror and would make every new linked worktree look like a
#   HEAD change on first sample.
# - cwd_key empty: last_git_fingerprint (legacy single-path callers).
tab_stats_git_fingerprint_for_path() {
  local workspace="${1:?missing workspace}"
  local session_name="${2:?missing session_name}"
  local cwd_key="${3:-}"
  tab_stats_read "$workspace" \
    | jq -r --arg s "$session_name" --arg p "$cwd_key" '
        (.sessions[$s] // {}) as $row
        | if ($p | tostring) != "" then
            ($row.git_fingerprints[$p] // "")
          else
            ($row.last_git_fingerprint // "")
          end
      ' 2>/dev/null || true
}

# Print the top N session names. Ranking key is
# activity_score + access_bonus(last_access_ms); rows with neither git
# activity nor access are omitted. Legacy dwell is diagnostic-only.
# Bindings expected at call sites: $now, $access_weight, $half_ms.
__TAB_STATS_RANK_SCORE_JQ='
  def has_git($v):
    (($v.activity_count // 0) | tonumber) > 0 or (($v.last_activity_ms // 0) | tonumber) > 0;
  def has_activity($v):
    has_git($v) or (($v.last_access_ms // 0) | tonumber) > 0;
  def access_bonus($v):
    (($v.last_access_ms // 0) | tonumber) as $la
    | if $la <= 0 then 0
      else
        (if ($now - $la) < 0 then 0 else ($now - $la) end) as $age
        | if $half_ms <= 0 then $access_weight
          else $access_weight * pow(2; -($age / $half_ms))
          end
      end;
  def rank_score($v):
    ((($v.activity_score // 0) | tonumber) + access_bonus($v));
  def rank_tier($v):
    if has_activity($v) then 1 else 0 end;
  def rank_recent($v):
    ([($v.last_activity_ms // 0), ($v.last_access_ms // 0), ($v.last_bump_ms // 0)] | max | tonumber);
  def rank_count($v):
    if (($v.activity_count // 0) | tonumber) > 0 then (($v.activity_count // 0) | tonumber)
    else (($v.raw_count // 0) | tonumber)
    end;
'
tab_stats_top_n() {
  local workspace="${1:?missing workspace}"
  local n="${2:-5}"
  local now half_ms
  now="$(tab_stats_now_ms)"
  half_ms=$((TAB_STATS_HALF_LIFE_DAYS * TAB_STATS_MS_PER_DAY))
  tab_stats_read "$workspace" | jq -r \
    --argjson n "$n" \
    --argjson now "$now" \
    --argjson access_weight "$TAB_STATS_ACCESS_WEIGHT" \
    --argjson half_ms "$half_ms" "
    $__TAB_STATS_RANK_SCORE_JQ
    (.sessions // {})
    | to_entries
    | map(select(has_activity(.value)))
    | sort_by([- rank_tier(.value), - rank_score(.value), - rank_recent(.value), - rank_count(.value), .key])
    | .[0:\$n]
    | .[].key
  "
}

# Same as top_n but emits the full record per line as TSV:
#   <session_name>\t<rank_score>\t<total_dwell_ms>\t<event_count>\t<rank_recent_ms>
tab_stats_top_n_tsv() {
  local workspace="${1:?missing workspace}"
  local n="${2:-5}"
  local now half_ms
  now="$(tab_stats_now_ms)"
  half_ms=$((TAB_STATS_HALF_LIFE_DAYS * TAB_STATS_MS_PER_DAY))
  tab_stats_read "$workspace" | jq -r \
    --argjson n "$n" \
    --argjson now "$now" \
    --argjson access_weight "$TAB_STATS_ACCESS_WEIGHT" \
    --argjson half_ms "$half_ms" "
    $__TAB_STATS_RANK_SCORE_JQ
    (.sessions // {})
    | to_entries
    | map(select(has_activity(.value)))
    | sort_by([- rank_tier(.value), - rank_score(.value), - rank_recent(.value), - rank_count(.value), .key])
    | .[0:\$n]
    | .[]
    | [.key,
       rank_score(.value),
       (.value.total_dwell_ms // 0),
       rank_count(.value),
       rank_recent(.value)]
    | @tsv
  "
}

# Emit every session as TSV with `__refresh_<ts>_<pid>` variants
# aggregated under their base name. Mirrors the lua-side
# `_rank_sessions` aggregation so the picker (Alt+x) and the brain
# (`tab_visibility.lua`) rank from the same projection of the data.
#   <base_session_name>\t<rank_tier_max>\t<rank_score_sum>\t<total_dwell_ms_sum>\t<event_count_sum>\t<rank_recent_ms_max>
# No N cap — caller filters/sorts as needed.
tab_stats_aggregated_tsv() {
  local workspace="${1:?missing workspace}"
  local now half_ms
  now="$(tab_stats_now_ms)"
  half_ms=$((TAB_STATS_HALF_LIFE_DAYS * TAB_STATS_MS_PER_DAY))
  tab_stats_read "$workspace" | jq -r \
    --argjson now "$now" \
    --argjson access_weight "$TAB_STATS_ACCESS_WEIGHT" \
    --argjson half_ms "$half_ms" "
    $__TAB_STATS_RANK_SCORE_JQ
    (.sessions // {})
    | to_entries
    | map(select(has_activity(.value)))
    | map({
        base: (.key | sub(\"__refresh_[0-9]+T[0-9]+_[0-9]+$\"; \"\")),
        rank_tier: rank_tier(.value),
        rank_score: rank_score(.value),
        total_dwell_ms: (.value.total_dwell_ms // 0),
        event_count: rank_count(.value),
        rank_recent_ms: rank_recent(.value)
      })
    | group_by(.base)
    | map({
        base: .[0].base,
        rank_tier: (map(.rank_tier) | max),
        rank_score: (map(.rank_score) | add),
        total_dwell_ms: (map(.total_dwell_ms) | add),
        event_count: (map(.event_count) | add),
        rank_recent_ms: (map(.rank_recent_ms) | max)
      })
    | .[]
    | [.base, .rank_tier, .rank_score, .total_dwell_ms, .event_count, .rank_recent_ms]
    | @tsv
  "
}
