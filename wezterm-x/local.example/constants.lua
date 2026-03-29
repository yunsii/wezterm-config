return {
  runtime_mode = 'hybrid-wsl',
  default_domain = 'WSL:your-distro-name',
  shell = {
    program = '/bin/zsh',
  },
  managed_cli = {
    ui_variant = 'light',
  },
  chrome_debug_browser = {
    -- Override executable if your browser binary is not on PATH.
    -- executable = 'google-chrome',
    -- Use a Windows path in hybrid-wsl and a local path in posix-local.
    user_data_dir = '/path/to/chrome-profile',
  },
  diagnostics = {
    wezterm = {
      enabled = false,
      level = 'info',
      debug_key_events = false,
      categories = {
        alt_o = true,
        chrome = true,
        workspace = true,
      },
    },
  },
}
