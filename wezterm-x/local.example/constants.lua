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
    user_data_dir = 'C:\\path\\to\\chrome-profile',
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
