# Host Helper Release Rollout

Use this doc when you are publishing a new Windows host-helper release, updating the version-pinned `release-manifest.json`, or testing the release-install path locally. This is **maintainer flow**, not a daily-workflow path — most contributors never touch it.

The architectural place of the helper itself (request flow, IPC, reuse policy, cache files) lives in [`architecture.md#windows-host`](./architecture.md#windows-host).

## When to use this

- You changed something in `native/host-helper/windows/...` that needs to land on machines without a local Windows `dotnet` SDK.
- You want to verify the release-install path on a machine that *does* have `dotnet` (force the release branch with the env var below).
- You hit a slow GitHub download and want to side-load a pre-fetched zip.

## Cutting a release

1. Run the GitHub Actions workflow [`.github/workflows/host-helper-release.yml`](/home/yuns/github/wezterm-config/.github/workflows/host-helper-release.yml) with a new `host-helper-v...` tag, or push that tag to trigger the workflow automatically.
2. Copy the release tag and SHA-256 from the workflow summary.
3. For non-draft releases, the workflow now opens a PR that updates `native/host-helper/windows/release-manifest.json` on top of the default branch.
4. If you need to update the manifest manually from a repo checkout:

   ```bash
   scripts/dev/update-host-helper-release-manifest.sh --tag host-helper-v2026.04.19.1 --sha256 <sha256>
   ```

5. Sync the runtime as usual ([`daily-workflow.md#runtime-sync`](./daily-workflow.md#runtime-sync)) so the updated manifest is copied to Windows targets.

## Forcing the release path locally

To exercise the release branch on a machine that already has Windows `dotnet`:

```bash
WEZTERM_WINDOWS_HELPER_INSTALL_SOURCE=release skills/wezterm-runtime-sync/scripts/sync-runtime.sh
```

Use `WEZTERM_WINDOWS_HELPER_INSTALL_SOURCE=local` when you want to verify the local-build path explicitly. Leave it unset for normal `auto` behavior.

To inspect what the installer chose, see the `install_source` / `release_archive_source` / `release_archive_path` / `release_download_url` fields documented in [`diagnostics.md#traceability`](./diagnostics.md#traceability), plus `helper-install-state.json` under `%LOCALAPPDATA%\wezterm-runtime\bin\`.

## Side-loading the release zip

When GitHub download speed is poor, the Windows helper installer checks these release-archive sources in order before it falls back to the manifest URL:

- `WEZTERM_WINDOWS_HELPER_RELEASE_ARCHIVE=C:\path\to\asset.zip`
- `%LOCALAPPDATA%\wezterm-runtime\artifacts\host-helper\<version>\<assetName>`
- `%LOCALAPPDATA%\wezterm-runtime\artifacts\host-helper\<assetName>`
- the existing `%LOCALAPPDATA%\wezterm-runtime\cache\downloads\<version>\<assetName>` cache entry

For network overrides, use one of:

- `WEZTERM_WINDOWS_HELPER_RELEASE_URL=https://.../asset.zip`
- `WEZTERM_WINDOWS_HELPER_RELEASE_BASE_URL=https://mirror.example.com/host-helper/<version>`

Both local archives and URL overrides are still verified against the manifest SHA-256 before installation.
