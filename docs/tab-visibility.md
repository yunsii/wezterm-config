# Tab Visibility

The tab-visibility pipeline answers: **of all tmux sessions a workspace
owns, which N should the WezTerm tab bar render directly, and how does
the user reach the rest?**

The shipped layout is **N visible tabs + 1 overflow tab**. Visible tabs
are spawned at workspace cold-open (top-N of the user's
`workspaces.lua` config order). The overflow tab is a single rotating
slot whose pane projects into a per-workspace browse session by default,
and switches to any other configured session when the user picks one
in the `Alt+x` picker. Total wezterm tab count stays at `N + 1`
regardless of how many sessions the user cycles through.

Behavior is **opt-in per workspace** via
`constants.tab_visibility.enabled_workspaces`; with no opt-in, every
workspace behaves byte-identical to before.

## Data flow — focus statistics

```
tmux client lands on session X (workspace W)
  └─ session-changed / client-attached hook
     └─ scripts/runtime/tab-stats-bump.sh "X"
        └─ resolves W from `tmux show-options -v -t X @wezterm_workspace`
           (set by open-project-session.sh; "default" when missing)
        └─ scripts/runtime/tab-stats-lib.sh tab_stats_bump W X
           └─ jq pipeline (single fork):
              1. decay every session weight by exp(-Δt_ms / half_life_ms * ln2)
              2. set last_bump_ms = now for every session
              3. on the bumped session: weight += 1, raw_count += 1
              4. normalize so max(weight) == 1.0
           └─ atomic tmp + rename into
              %LOCALAPPDATA%\wezterm-runtime\state\tab-stats\<workspace>.json
```

Throttle: bumps for the same session within 500 ms collapse to one.
Lock: per-file `flock -x 9` so concurrent hooks (e.g. attach + immediate
session-changed) serialize without losing bumps.

## State schema

One file per workspace, slug-sanitized into `<workspace>.json`:

```json
{
  "version": 1,
  "half_life_days": 7,
  "sessions": {
    "wezterm-config": {
      "weight": 1.0,
      "last_bump_ms": 1777343497366,
      "raw_count": 47
    },
    "ai-video-collection": {
      "weight": 0.42,
      "last_bump_ms": 1777343497366,
      "raw_count": 19
    }
  }
}
```

- `weight` ∈ [0, 1]. Always renormalized so the most-recently-bumped
  session is exactly 1.0. Used directly as the rank key (top-N).
- `last_bump_ms` — wall-clock epoch ms of the most recent bump. Drives
  the decay calculation on the next bump.
- `raw_count` — lifetime focus count, never decayed. Diagnostic only;
  PR 2 may surface it in the picker as a "lifetime focus" chip.

## Decay math

`weight_after_decay = weight_before * 2 ^ ( -Δt_ms / (half_life_days * 86_400_000) )`

→ At `half_life_days = 7`, a session's weight halves every 7 days of
inactivity. After 14 days the contribution is ¼; after 30 days roughly
5%. Long-vacation behavior: all sessions decay by the same factor while
the user is away, so the **relative ordering is preserved** and the
top-N set on return matches the set when the user left. The first focus
events after a long break can promote new sessions into the top-N
quickly because the decayed competition is small.

## Why per-workspace?

Each workspace has its own pool of repo-family tmux sessions; cross-
workspace ranking would mix unrelated projects. The `default` workspace
is also tracked (so ad-hoc shells can be diagnosed) but has no
managed-session metadata, so its bumps land on free-form session names.

## CLI helpers

`scripts/runtime/tab-stats-lib.sh` exposes:

- `tab_stats_bump <workspace> <session_name>` — write path used by the
  hook. Throttled, atomic, decay+normalize on every call.
- `tab_stats_read <workspace>` — print the raw JSON.
- `tab_stats_top_n <workspace> <n>` — newline-separated session names
  ordered by `weight desc, raw_count desc, name asc`.
- `tab_stats_top_n_tsv <workspace> <n>` — same but TSV with weight,
  raw_count, last_bump_ms.

## Layout — visible tabs + overflow tab

Opt in per workspace from `wezterm-x/local/constants.lua`:

```lua
tab_visibility = {
  enabled_workspaces = { work = true, config = true },
  spawn_visible_only = true,    -- cap startup spawn to visible_count
  -- visible_count = 5,
  -- half_life_days = 7,
}
```

Both map form (`{ work = true }`) and list form (`{ 'work', 'config' }`)
are accepted. Without `spawn_visible_only`, `enabled_workspaces` is a
no-op (the layout is a single coherent feature; flagging it on without
the cap leaves no observable change). The cap is separately gated so
the user must consciously accept the lifecycle change.

### Cold open (`Alt+w` to a workspace with no live window)

When `spawn_visible_only` is set:

1. `Workspace.open` reads `workspaces.lua` items in their declared
   order and caps at `visible_count`.
2. Spawns those N as wezterm tabs via the existing managed-spawn path
   (`open-project-session.sh` per item).
3. Appends one extra **overflow tab** with title `…`. Its pane runs
   inline bash that creates the per-workspace browse session
   `wezterm_<slug>_overflow` if missing (cold-start safe: tmux
   `new-session -d` fires only on first open) and execs into
   `tmux attach -t <browse>`.
4. The overflow pane records its tty into
   `/tmp/wezterm-overflow-<slug>-tty.txt` before the exec. That tty is
   the stable client identifier the picker dispatch script uses to
   `tmux switch-client -c <tty>` later.

Items beyond the cap are not spawned. Their sessions don't yet exist
in tmux either — the tab bar shows N+1 tabs and the configured project
list is otherwise invisible until the user reaches for `Alt+x`.

### Hot open (`Alt+w` while the workspace window already exists)

`Workspace.open` finds the existing window and falls through to
`sync_workspace_tabs`. Cap is **soft on hot open**: `desired_items`
(the spawn loop input) is the capped set, but `prune_keep_items` (the
prune loop input) is the full configured list, and the alignment-check
fast-switch path uses `prune_keep_items`. Net behavior:

- Tabs already spawned before the cap turned on stay alive (no
  surprise kill on a stray `Alt+w`).
- Sessions that fell out of the spawn window during the same workspace
  lifetime don't re-spawn on `Alt+w` (the cap holds for the lifetime
  of that workspace window).
- `prune_workspace_tabs` and `workspace_is_aligned` both skip the
  overflow tab via `is_overflow_tab` since it is owned by tab_visibility,
  not by `workspaces.lua`.

### `Alt+x` — single-tab session rotation

`Alt+x` (manifest id `tab.overflow-picker`, wezterm layer, forwarded
into the active tmux pane via user-key 4) opens a tmux `display-menu`
listing **all** configured sessions for the active workspace, marked
by current state:

- `●` visible — already a wezterm tab.
- `◐` warm    — tmux session exists but not in a wezterm tab (currently
  living detached or projected into the overflow pane).
- `○` cold    — no tmux session yet.

Picker dispatch (`tab-overflow-dispatch.sh`):

| State | Path | Result |
| --- | --- | --- |
| `●` visible | emit `tab.activate_visible` event | `Workspace.activate_only` brings that wezterm tab forward |
| `◐` warm | `tab-overflow-attach.sh` runs `tmux switch-client -c <tty> -t <session>` + emits `tab.activate_overflow` | overflow pane retargets to that session, wezterm jumps to overflow tab |
| `○` cold | `tab-overflow-cold-spawn.sh` runs `tmux new-session -A -d -s <session>` + the same attach + activate path | new bare bash session created, projected into overflow tab |

**Total wezterm tab count stays at `visible_count + 1` regardless of
how many sessions the user rotates through**; the pool is held in
tmux server memory, the wezterm side is a finite porthole.

### Cold-start agent gap

`tab-overflow-cold-spawn.sh` creates a **bare bash session**, not the
managed agent (claude / codex). The agent launch command is composed
lua-side from `constants.managed_cli` and is not currently available
to the bash dispatch path; plumbing it through belongs to the warm
preheat work below. For now, after rotating into a cold session the
user runs `claude --continue` themselves — better than the previous
behavior of silently spawning a new wezterm tab outside the cap.

### Long-vacation behavior

Indexed exponential decay is order-preserving: 14 days off with no
bumps shrinks every weight by the same factor, so the top-N set is
identical when you return. The first focus events after a break still
weigh the same as before; new sessions can promote into top-N within
a day or two of regular use as decayed competitors fall behind. The
ranking still drives the picker's sort order even though it does not
re-shuffle the visible tabs (those are pinned to whatever `Workspace
.open` decided at cold-open).

### Pieces

| Layer | File | Role |
| --- | --- | --- |
| Brain | `wezterm-x/lua/ui/tab_visibility.lua` | top-N computation, `is_enabled` / `spawn_capped` predicates, workspace slug |
| Constants | `wezterm-x/lua/constants.lua` | `tab_visibility` config block (visible_count, enabled_workspaces, spawn_visible_only, …) |
| Spawn cap + items snapshot | `wezterm-x/lua/workspace_manager.lua` | caps `Workspace.open`, threads `prune_keep_items` through `sync_workspace_tabs`, writes per-workspace items snapshot |
| Overflow tab spawn | `wezterm-x/lua/workspace/tabs.lua` `spawn_overflow_tab` | creates the `…` tab, browse session, records tty |
| Manifest + handler | `wezterm-x/commands/manifest.json` + `wezterm-x/lua/ui/action_registry.lua` | `tab.overflow-picker` → `Alt+x`, forwards user-key 4 |
| tmux user-key | `tmux.conf` | `bind-key -n User4` runs `tab-overflow-menu.sh` |
| Picker menu | `scripts/runtime/tab-overflow-menu.sh` | reads items snapshot, marks visible/warm/cold, builds `tmux display-menu` |
| Dispatch | `scripts/runtime/tab-overflow-dispatch.sh` | per-state routing (event, attach, cold-spawn) |
| switch-client | `scripts/runtime/tab-overflow-attach.sh` | `tmux switch-client -c <tty> -t <session>` |
| Cold spawn | `scripts/runtime/tab-overflow-cold-spawn.sh` | `tmux new-session -A -d` + attach |
| Event handlers | `wezterm-x/lua/titles.lua` | `tab.activate_visible` / `tab.activate_overflow` / `tab.spawn_overflow` (cold fallback) |

### Attention picker fallback

`tmux-attention-menu.sh` previously rendered `?/?/...` for any
attention entry whose `wezterm_pane_id` had no matching live wezterm
pane (capped session, archived recent row whose pane is gone, etc.).
The picker now falls back to parsing the `tmux_session` name shape
`wezterm_<workspace>_<repo_label>_<10hex>` so the row shows
`work/<repo>/...` instead of `?/?/...`.

### Unified pane→tmux_session map (drives attention focus + jumps)

`wezterm_pane_id` is mux-global and lifecycle-bound: spawn-cap
eviction, workspace close + reopen, refresh-session, and overflow
rotation all change the id without changing the session identity.
The `tmux_session` name (computed by `tmux_worktree_session_name_for_path`
from workspace + cwd) is the stable handle. Attention's render and
jump paths therefore resolve focus by **"which session does this
wezterm pane currently host?"** and match against `entry.tmux_session`,
never by the stored `wezterm_pane_id`.

`tab_visibility.lua` owns one map: `_G.__WEZTERM_PANE_TMUX_SESSION
[pane_id] = session_name`. Two storage tiers:

1. **In-memory** — `spawn_overflow_tab` populates the overflow pane
   with its initial browse session (`wezterm_<slug>_overflow`).
   `titles.lua`'s `tab.activate_overflow` event handler refreshes the
   value after each Alt+x pick (`set_pane_session(overflow_pane_id,
   target_session)`). Covers the rotating overflow pane.
2. **On-disk** — `scripts/runtime/open-project-session.sh` writes
   `<runtime_state>/state/pane-session/<wezterm_pane_id>.txt` with
   the `session_name` it just created or reused at managed-session
   creation. Covers visible managed tabs whose pane id is fixed for
   the lifetime of that wezterm tab.

Public readers in `tab_visibility.lua`:

- `session_for_pane(pane_id)` — in-memory tier, fall back to file.
- `pane_for_session(session_name)` — reverse lookup; in-memory walk,
  fall back to scanning the on-disk dir.

Consumers (all in `attention.lua`):

- `is_entry_focused(entry, focused_pane_id)` — `session_for_pane(focused_pane_id) == entry.tmux_session`, plus the existing tmux-pane-level guard for split-pane sessions.
- `activate_in_gui(pane_id_value, window, source, opts)` — when `opts.tmux_session` is set, `pane_for_session` finds the wezterm pane currently hosting it (visible tab or overflow) and that pane gets activated. Workspace switch is automatic when the target lives elsewhere. Falls back to literal `pane_id_value` when no session hint is present.
- `tab_badge(tab_info)` — active pane's hosted session selects the matching attention entry; `done` is suppressed only when `is_entry_focused` says yes.

**Picker payload** (Alt+/) appends the resolved session name as the
trailing v1 field: `v1|jump|<sid>|<wp>|<sock>|<win>|<pane>|<session>`
(and `v1|recent|...|<session>`). Both Go picker (`cmd_attention.go`)
and bash fallback (`tmux-attention-picker.sh`) producers resolve the
name via `tmux -S <socket> display-message -t <window> '#S'`. Lua's
`parse_jump_payload` is nil-tolerant — older payloads without the
trailing field still parse and drop into the legacy literal-pane
fallback.

### Overflow tab identity via pane user_var

Pruning / alignment-check uses `tab:active_pane():get_user_vars()
['we_tab_role'] == 'overflow'` to identify the overflow tab —
`spawn_overflow_tab` sets that user var on the placeholder pane.
Title-based detection was fragile: any code path that called
`tab:set_title` (refresh-session, user-driven rename) silently
de-classified the tab and let prune kill it. The user_var marker is
set by lua and only touched by lua, so external resets cannot drop it.

The browse session also gets a server-side tag:
`tmux set-option -t wezterm_<slug>_overflow -q @wezterm_session_role
tab_visibility_overflow_browse`. Future tooling can identify the
session deterministically without parsing the name.

Full attention render + transition rules: see
[`docs/agent-attention.md`](./agent-attention.md), particularly the
*Focus-based auto-ack* subsection's "Match by `tmux_session`" point.

## What's not done yet

- **No warm preheat layer.** A natural next step is to keep the next
  M ranks beyond `visible_count` running as detached tmux sessions
  (`tmux new-session -d -s <name> ... <managed-agent>`) so promotions
  through the picker incur ~16ms switch-client instead of ~500ms cold
  start. Requires plumbing the managed-agent launch command into bash.
- **Cold-spawn agent.** Same plumbing — once it lands, cold sessions
  picked from `Alt+x` can come up with the agent already running.
- **No automatic session lifecycle.** Sessions live as long as their
  tmux session lives. Killing detached sessions on demotion / TTL
  belongs to the warm-preheat work above.
