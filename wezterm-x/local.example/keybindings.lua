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
--   * Chord keys (space-separated) are NOT supported here yet. To change a
--     Ctrl+k chord leaf (pane.split-vertical, worktree.quick-create-*), edit
--     tmux.conf directly for now. See docs/keybindings.md for the roadmap.
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

  -- ── Worktree navigation (wezterm layer only) ──────────
  -- ['worktree.picker']                 = 'Alt+g',
  -- ['worktree.cycle-next']             = 'Alt+Shift+g',
  -- Chord leaves (Ctrl+k g d/t/h/r) are not customizable via this file yet.

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
