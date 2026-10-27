# Volume Control

A macOS menu-bar volume mixer: per-app volume/mute/output routing, real
per-device volume levels, and a mic-mixer for calls.

<img width="531" height="425" alt="Screenshot 2026-10-27 at 20 31 25" src="https://github.com/user-attachments/assets/322e6968-ddbb-426e-8d85-0126c04d89f7" />

Built entirely on Apple's public CoreAudio APIs — in particular the process-tap
API (`AudioHardwareCreateProcessTap`, macOS 14.2+) — rather than any private
framework or kernel extension. The virtual microphone device is a from-scratch
`AudioServerPlugIn` (CoreAudio HAL plugin), also public API.

## Features

**Output tab**
- Per-app volume, mute, and output-device routing — every app playing audio
  gets a live slider the moment it starts, no manual setup per app.
- A pinned System Sounds control for alerts/notifications, alongside every
  other app.
- Device Levels — macOS's own per-device stored volume/mute for every
  connected output device, exposed directly (this is why a Bluetooth headset
  and the built-in speakers can sound very different at "the same" volume).
- Single/Multiple device-mode switch — see at a glance whether apps are split
  across different output devices, and consolidate back to one in a click
  (headphones/earbuds prioritized, then built-in speakers).
- Device-type icons inferred from name and transport: MacBook speakers,
  AirPods family, Beats, earbuds, headphones, soundbar/home theater, generic
  Bluetooth/AirPlay/HDMI.

**Input tab**
- Mix the real microphone (adjustable sensitivity, instant mute) with any
  combination of currently-playing apps' audio, output through a virtual
  "Volume Control Mic Mix" device that FaceTime/WhatsApp/Zoom/etc. can select
  as their microphone — share an app's audio on a call without hunting for
  the right window or asking "can you hear that?"
- Off by default: nothing touches the microphone, and no permission prompt
  appears, until Input Mixing is explicitly turned on.
- One-click installer for the virtual mic device, using a single native
  macOS admin-password prompt rather than manual terminal steps.

**Preferences**
- Launch at Login (via `SMAppService`, the real launchd mechanism).
- Default expand/collapse state per section.
- About panel.

## Requirements

- macOS 14.2 or later (Sonoma) — the per-process audio tap API this app is
  built on was introduced in 14.2.
- Xcode command line tools (`xcode-select --install`) to build from source.

## Installation

There's no signed/notarized release yet, so building from source is the only
option for now:

```bash
git clone https://github.com/hashedalgorithm/volume-control.git
cd volume-control
./Scripts/make_app_bundle.sh
open ~/Applications/VolumeControl.app
```

This also builds and embeds the virtual-mic HAL plugin used by the Input tab
(nothing is installed system-wide until you explicitly click "Install Virtual
Mic Device" from within the app). The app is ad-hoc signed for local use, so
macOS Gatekeeper may ask you to confirm opening it the first time
(`System Settings > Privacy & Security`, or right-click → Open).

For quick iteration without packaging into a `.app` (status-item popover
positioning and some permission prompts behave slightly differently
unpackaged):

```bash
swift build
.build/debug/VolumeControl
```

## Usage

- Click the menu-bar icon to open the panel.
- **Output tab**: adjust any app's volume/mute/output device directly;
  expand **Device Levels** to see or fix a specific device's own stored
  volume; use the **Single/Multiple** switch next to the tabs to consolidate
  every app onto one output device.
- **Input tab**: turn on **Input Mixing**, set mic sensitivity, toggle on
  the apps whose audio you want mixed into your mic, then select "Volume
  Control Mic Mix" as the microphone in your call app.
- **Preferences…** (bottom-right of the panel): Launch at Login and default
  section state.

First use of per-app routing triggers a system permission prompt for
system-audio recording; first use of Input Mixing triggers a microphone
permission prompt. Both are one-time, standard macOS TCC prompts.

## How it works

- **Per-app volume/routing**: a private `CATapDescription` process tap mutes
  the app's direct hardware output and captures its audio; the captured
  samples are re-rendered through an `AVAudioEngine` bound to whichever
  output device is chosen, at the chosen volume. No virtual driver needed
  for this part — see `Sources/VolumeControl/ProcessAudioManager.swift`.
- **Mic mixing**: the real microphone and each selected app's tapped audio
  are captured via raw CoreAudio IOProcs (not `AVAudioEngine` — its input
  node proved unreliable both when pinned to a specific device and when
  left to follow the system default), resampled to a common format, and
  summed sample-by-sample with soft limiting in a dedicated output IOProc
  bound to the virtual mic device — see
  `Sources/VolumeControl/InputMixEngine.swift`.
- **Virtual mic device**: `HALPlugin/VolumeControlMicMix.driver`, a minimal
  CoreAudio `AudioServerPlugIn` written directly against Apple's
  `<CoreAudio/AudioServerPlugIn.h>` contract — a single-writer loopback
  device (VolumeControl.app writes, call apps read), so no in-driver mixing
  logic is needed. See `HALPlugin/src/VolumeControlMicMix.c`.

## Project layout

```
Sources/VolumeControl/
  AudioDeviceManager.swift      device enumeration, per-device/master volume
                                 and mute, device-type icon inference
  AudioMixerModel.swift         Output tab state: per-app routes, System
                                 Sounds, Master Volume, Device Levels, mode
  ProcessAudioManager.swift     process enumeration; ProcessAudioRoute
                                 (per-app capture/mute/re-render/reconfigure)
  AudioRingBuffer.swift         ring buffer between capture and playback
  InputMixEngine.swift          Input tab: mic + per-app sources -> one engine
  InputTabView.swift            Input tab SwiftUI view
  MicMixInstaller.swift         installs the HAL plugin via admin prompt
  PopoverController.swift       status item + anchored panel window
  MixerPanelView.swift          Output tab SwiftUI view
  PreferencesView.swift         Preferences window content
  PreferencesWindowController.swift
  PreferenceKeys.swift          shared UserDefaults keys
  main.swift                    entry point (menu-bar only, no Dock icon)

HALPlugin/                      VolumeControlMicMix.driver (CoreAudio
                                 AudioServerPlugIn) + its C source and build
                                 script

Scripts/
  make_app_bundle.sh            builds the app + HAL plugin, packages .app
  relaunch.sh                   rebuilds and relaunches cleanly for dev

docs/install-micmix.md          manual install steps for the virtual mic
                                 device (the in-app installer is the normal
                                 path; this is the fallback)
```

## Contributing

Issues and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).
