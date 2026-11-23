# Changelog

All notable changes to Volume Control are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.13] - 2026-11-23

### Added
- **In-app auto-updater (OTA-style)**: Preferences → Updates checks GitHub Releases and,
  if a newer version exists, downloads just the two binaries that actually change (the
  app executable and the HAL mic-mix driver) instead of the full DMG, swaps them into
  the installed app, re-signs, and relaunches. Only updates the app bundle's own copy of
  the driver -- the system-installed one at `/Library/Audio/Plug-Ins/HAL` still needs
  the existing manual reinstall if it changes.
- **Global boost multiplier**: Preferences → Boost, a 0-3x slider applied on top of
  every app's own volume/boost, live for whatever's already playing.
- **Output Priority**: Preferences section with a reorderable device list -- the first
  currently-connected device wins and is applied to the system default output and to
  every app without its own explicit device pick, with automatic fallback/recovery as
  devices connect and disconnect.
- **Device Levels group volume**: a device's slider in the main panel now also scales,
  in software, every app explicitly routed to that device (per-app pick or priority
  routing) -- turn down everything going to one speaker without hunting down each app.
  Devices with no readable native CoreAudio volume at all (e.g. some HDMI
  audio-extractor outputs) now show a row too, driven purely by this.
- **Popup behavior preferences**: toggle "close on outside click," plus an auto-hide
  timer (5-120s, default 10s) with its own enable/disable switch.
- **Error log**: Preferences → Logs. Critical errors (failed device binds, stuck
  routes, startup cleanup) are written to a small rotating file under this app's own
  Application Support folder, to make bugs easier to track down after the fact.
- **Startup self-healing**: destroys any leftover per-app tap/aggregate devices left
  behind by a previous unclean shutdown before creating new ones -- the suspected
  mechanism behind a hang that previously required a full reboot to clear.

### Changed
- Removed the "Custom…" boost option and its inline percent field -- presets cover the
  same need. Existing saved custom boost values keep working exactly as before (same
  gain math, same display); there's just no way to create new ones from the UI anymore.

### Fixed
- A route that failed to bind a specific output device now retries once, then backs off
  for 15 seconds per app instead of retrying every single 2-second refresh forever --
  the likely real mechanism behind the popup appearing to hang indefinitely after an
  abrupt shutdown, until a full reboot.
