# Graphite Pearl Cursor

English | [简体中文](README.zh-CN.md)

A Windows 11 cursor theme with pearl gradients, rounded shapes and a symmetric 33° pointer.

![Theme preview](package/GraphitePearl/preview.png)

## Features

- 17 cursor roles, including two animated states and matching upright link and alternate cursors.
- Static sizes: 32–128 px. Animated sizes: 32, 48 and 64 px.
- Per-user installation with backups and restoration.

## Install

Download `Graphite-Pearl-Cursor-Windows.zip` from Releases and extract it.
Open PowerShell from Windows in the extracted `GraphitePearl` folder, then run:

```powershell
.\Apply.ps1
```

No administrator privileges are required. The installer applies the cursors,
synchronizes the current desktop theme's cursor entries and disables pointer
changes by desktop themes. Your pointer size setting is preserved.

Files and backups use `%LOCALAPPDATA%\GraphitePearl`. To restore, pass the
installation's `BackupFile` path to `Apply.ps1` with `-RestoreBackup`.
Keep the backup and previous cursor files until restoration is no longer needed.

## Build and verify

Requires Windows, Python 3.10+ and Pillow. From the repository root:

```powershell
py -m pip install -r requirements.txt
```

```powershell
py .\source\build_pearl_theme.py
```

```powershell
py .\source\validate_pearl_theme.py
```

```powershell
.\source\test_pearl_theme_settings.ps1
```

Output: `package/GraphitePearl/` and the installation ZIP.
These commands do not change your active cursors.

## License

Code and documentation: [MIT](LICENSE). Artwork: [CC BY 4.0](LICENSE-ASSETS.md).
Attribution and asset provenance: [Notices](THIRD_PARTY_NOTICES.md).
