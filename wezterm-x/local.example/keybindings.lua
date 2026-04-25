-- Optional local override for keyboard shortcuts. Copy this file to
-- wezterm-x/local/keybindings.lua and uncomment the bindings you want to
-- change. Missing file = no overrides. Reload WezTerm after editing.
--
-- Value shapes (VS Code keybindings.json style, Lua-flavored):
--   [id] = 'Ctrl+Shift+v'   -- string: replace the single default key
--   [id] = false            -- disable the id (all variants skipped)
--   [id] = {                -- list: per-variant remap, args required for
--     { key = 'Cmd+1', args = 1 },   multi-hotkey ids like tab.select-by-index
--     { key = 'Cmd+9', args = 9 },
--   }
--
-- Key string rules:
--   * '+' joins modifiers: Ctrl / Shift / Alt (Opt, Option, Meta) / Cmd (Super, Win).
--   * Last token is the main key (case-preserved: 'Ctrl+Shift+v' vs 'Ctrl+Shift+V').
--   * Chord keys are supported for tmux-chord ids (pane.split-*, pane.close-current,
--     worktree.quick-create-*, worktree.reclaim-current). Write the full chord
--     path: 'Ctrl+k s' to rebind the leaf, 'Ctrl+k g e' for a worktree chord
--     leaf. Only the final segment is consumed (the prefix stays Ctrl+k at the
--     tmux side); rerun wezterm-runtime-sync after editing so the tmux chord
--     table regenerates.
--
-- Discover ids: wezterm-x/commands/manifest.json, or run
--   scripts/dev/hotkey-usage-report.sh
--
-- Invalid entries (unknown id, bad key string, shape mismatch) are dropped
-- with a warn line at WezTerm startup — check the logger category
-- 'keybindings' in the diagnostics log.

return {
  -- ── Clipboard ─────────────────────────────────────────
  -- ['clipboard.copy-or-sigint']        = 'Ctrl+c',
  -- ['clipboard.copy-selection-strict'] = 'Ctrl+Shift+c',
  -- ['clipboard.paste-smart']           = 'Ctrl+v',
  -- ['clipboard.paste-plain']           = 'Ctrl+Shift+v',
  -- ['link.open-in-viewport']           = 'Alt+l',

  -- ── Panes / chord prefix ──────────────────────────────
  -- ['command-palette.chord-prefix']    = 'Ctrl+k',  -- tmux.conf still binds
  --                                                  -- the old Ctrl+k until
  --                                                  -- the chord renderer lands.
  -- ['pane.rotate-next']                = 'Alt+o',
  -- ['command-palette.open']            = 'Ctrl+Shift+p',
  -- ['command-palette.open-native']     = 'Ctrl+Shift+;',

  -- ── Tabs ──────────────────────────────────────────────
  -- ['tab.next']                        = 'Alt+n',
  -- ['tab.previous']                    = 'Alt+Shift+n',
  -- ['tab.select-by-index'] = {
  --   { key = 'Cmd+1', args = 1 },
  --   { key = 'Cmd+2', args = 2 },
  --   { key = 'Cmd+3', args = 3 },
  --   { key = 'Cmd+4', args = 4 },
  --   { key = 'Cmd+5', args = 5 },
  --   { key = 'Cmd+6', args = 6 },
  --   { key = 'Cmd+7', args = 7 },
  --   { key = 'Cmd+8', args = 8 },
  --   { key = 'Cmd+9', args = 9 },
  -- },

  -- ── VS Code / Chrome debug ────────────────────────────
  -- ['vscode.open-current-dir']             = 'Alt+v',
  -- ['chrome.open-debug-profile']           = 'Alt+b',
  -- ['chrome.open-debug-profile-visible']   = 'Alt+Shift+b',

  -- ── Worktree navigation ──────────────────────────────
  -- ['worktree.picker']                 = 'Alt+g',
  -- ['worktree.cycle-next']             = 'Alt+Shift+g',
  -- ['worktree.quick-create-dev']       = 'Ctrl+k g d',  -- chord leaf
  -- ['worktree.quick-create-task']      = 'Ctrl+k g t',
  -- ['worktree.quick-create-hotfix']    = 'Ctrl+k g f',  -- rebind h -> f
  -- ['worktree.reclaim-current']        = 'Ctrl+k g r',

  -- ── Panes (chord leaves) ──────────────────────────────
  -- ['pane.split-vertical']             = 'Ctrl+k s',    -- rebind v -> s
  -- ['pane.split-horizontal']           = 'Ctrl+k v',    -- rebind h -> v
  -- ['pane.close-current']              = false,         -- disable
  -- Chord leaves live in the tmux chord tables. Edits here take effect only
  -- after wezterm-runtime-sync regenerates wezterm-x/tmux/chord-bindings.generated.conf.

  -- ── Agent attention ───────────────────────────────────
  -- ['attention.jump-waiting']          = 'Alt+,',
  -- ['attention.jump-done']             = 'Alt+.',
  -- ['attention.overlay']               = 'Alt+/',

  -- ── Workspace switch ──────────────────────────────────
  -- ['workspace.switch-default']        = 'Alt+d',
  -- ['workspace.switch-work']           = 'Alt+w',
  -- ['workspace.switch-config']         = 'Alt+c',
  -- ['workspace.cycle-next']            = 'Alt+p',
  -- ['workspace.close-current']         = 'Alt+Shift+x',

  -- ── Application-level ─────────────────────────────────
  -- ['app.quit']                        = 'Alt+Shift+q',
}
