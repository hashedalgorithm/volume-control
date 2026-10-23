# Volume Control

Menu-bar macOS utility: per-app volume/routing and output-device switching,
built on Apple's public CoreAudio process-tap API (`AudioHardwareCreateProcessTap`,
macOS 14.2+) rather than any private framework.

## Layout

- `Sources/VolumeControl/` — the menu-bar app (Swift Package)
  - `AudioDeviceManager.swift` — enumerate/set the default output device
  - `ProcessAudioManager.swift` — list apps playing audio; per-app capture,
    mute-original, re-route to a chosen output device at a chosen volume
  - `AudioRingBuffer.swift` — lock-protected ring buffer between the tap's
    capture callback and the playback render callback
  - `MenuBarController.swift` — status-bar menu UI
  - `main.swift` — entry point (menu-bar only, no Dock icon)

## Build

```bash
swift build
.build/debug/VolumeControl
```

Requires macOS 14.2+ (process-tap API). First use of per-app routing triggers
a system permission prompt for system-audio recording.

## Status

- [x] Output device switcher
- [x] Per-app volume + routing via process taps
- [ ] Virtual "mic mix" input device (mic + chosen apps' audio combined, to
      feed into FaceTime/WhatsApp/etc. as the call microphone) — in progress,
      implemented as a CoreAudio `AudioServerPlugIn` (HAL plugin)
