# mpv-subhanallah

A very lightweight mpv subtitle search and download plugin using Subdl or OpenSubtitles API.

## Features

- F5 searches using the current video filename.
- F6 opens manual search.
- F7 opens settings.
- SubDL is the default provider; OpenSubtitles is optional.
- Keyboard and mouse result selection.
- Downloads beside writable local videos and loads the subtitle immediately.

## Windows installer

Download `mpv-subhanallah-installer-v2026.08.16.exe`, run it, and follow the prompts. It installs into `%APPDATA%\mpv` and asks for the provider, API key, languages and key bindings.

Only one provider is required. OpenSubtitles username and password are optional, and blank values can be edited later from F7. Because the EXE is not code-signed, Windows may show a SmartScreen warning.

API keys:

- [SubDL](https://subdl.com/developers)
- [OpenSubtitles](https://www.opensubtitles.com/consumers)

## Manual install

Download `mpv-subhanallah-v2026.08.16.zip` and copy its `scripts` and `script-opts` folders into your mpv config directory:

| Platform | Default mpv config directory |
| --- | --- |
| Windows | `%APPDATA%\mpv` |
| Linux | `~/.config/mpv` |
| macOS | `~/.config/mpv` |

Enter one provider's API key in `script-opts/mpv-subhanallah.conf`. You can also leave it blank and configure the plugin from F7.

Custom `MPV_HOME` or `--config-dir` locations take precedence over these defaults.

## Requirements

- mpv 0.40 or newer
- curl

The Lua plugin works on Windows, macOS and Linux. The EXE installer is Windows-only.

## Build a release

On Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build-release.ps1
```

The current date is used automatically in `YYYY.MM.DD` format. The EXE and manual-install ZIP are written to `dist`.
