# Volume Control

A macOS menu-bar volume mixer: per-app volume/mute/output routing, real
per-device volume levels, and a mic-mixer for calls — built from Apple's
public CoreAudio process-tap API (`AudioHardwareCreateProcessTap`, macOS
14.2+) rather than any private framework or kernel extension.

## Features

**Output tab**
- Per-app volume, mute, and output-device routing — every app playing audio
  gets a live slider the moment it starts.
- Master Volume (the real system output volume) and a pinned System Sounds
  control for alerts/notifications.
- Device Levels — macOS's own per-device stored volume/mute for every
  connected output device.
- Single/Multiple device-mode switch: see and consolidate whether apps are
  split across devices.
- Device-type icons (MacBook speakers, AirPods family, Beats, earbuds,
  headphones, soundbar/home theater, generic Bluetooth/AirPlay/HDMI).

**Input tab**
- Mix the real microphone (adjustable sensitivity, instant mute) with any
  combination of currently-playing apps' audio, output through a virtual
  "Volume Control Mic Mix" device that FaceTime/WhatsApp/Zoom/etc. can select
  as their microphone — share app audio on a call without window-hunting.
- Off by default; nothing touches the mic until explicitly turned on.
- One-click installer for the virtual mic device (bundled HAL plugin).

**Preferences**
- Launch at Login (`SMAppService`), default section expand state, About panel.

## Layout

- `Sources/VolumeControl/` — the menu-bar app (Swift Package)
  - `AudioDeviceManager.swift` — device enumeration, per-device/master volume
    and mute, device-type icon inference
  - `AudioMixerModel.swift` — Output tab's state: per-app routes, System
    Sounds, Master Volume, Device Levels, Single/Multiple device mode
  - `ProcessAudioManager.swift` — process enumeration; `ProcessAudioRoute`
    (per-app capture via process tap, mute-original, re-render through a
    chosen output device at a chosen volume, live format/default-device
    reconfiguration)
  - `AudioRingBuffer.swift` — lock-protected ring buffer between capture and
    playback render callbacks
  - `InputMixEngine.swift` / `InputTabView.swift` — Input tab: mic capture +
    per-app mix sources combined into one `AVAudioEngine`, bound to the
    virtual mic device
  - `MicMixInstaller.swift` — installs the bundled HAL plugin via a native
    admin-password prompt
  - `PopoverController.swift` — menu-bar status item + the anchored panel
  - `MixerPanelView.swift` — the Output tab SwiftUI view
  - `PreferencesView.swift` / `PreferencesWindowController.swift` /
    `PreferenceKeys.swift` — Preferences window
  - `main.swift` — entry point (menu-bar only, no Dock icon)
- `HALPlugin/` — `VolumeControlMicMix.driver`, a from-scratch CoreAudio
  `AudioServerPlugIn` (see `HALPlugin/src/VolumeControlMicMix.c`) backing the
  Input tab's virtual mic device
- `Scripts/make_app_bundle.sh` — wraps the build in a real `.app` bundle
  (also builds and embeds the HAL plugin); `Scripts/relaunch.sh` — rebuilds
  and relaunches cleanly during development
- `docs/install-micmix.md` — manual install steps for the virtual mic device
  (the in-app installer in the Input tab is the normal path)

## Build

```bash
./Scripts/make_app_bundle.sh
open ~/Applications/VolumeControl.app
```

Or for quick iteration without packaging:

```bash
swift build
.build/debug/VolumeControl
```

Requires macOS 14.2+ (process-tap API). First use of per-app routing
triggers a system permission prompt for system-audio recording; first use
of Input Mixing triggers a microphone permission prompt.

## Status

- [x] Output device switcher, per-app volume/mute/routing
- [x] Master Volume, System Sounds, Device Levels, Single/Multiple device mode
- [x] Input tab: mic + app audio mixing into a virtual call microphone
- [x] Preferences (Launch at Login, default section state, About)
