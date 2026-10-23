# Installing the Mic Mix virtual device

This installs `VolumeControlMicMix.driver`, a CoreAudio `AudioServerPlugIn`
(same category as BlackHole/Loopback) that shows up as a normal selectable
microphone named **"Volume Control Mic Mix"**. VolumeControl.app will write
mixed mic + app audio into it; FaceTime/WhatsApp/Zoom/etc. read it like any
other mic by selecting it in their own input picker.

**What this touches:** copies one file to `/Library/Audio/Plug-Ins/HAL`
(needs your admin password) and restarts `coreaudiod`, the system audio
daemon. Restarting it briefly cuts all system audio for a second or two —
expected, not a bug. If anything goes wrong, [Uninstall](#uninstall) below
undoes it completely; no reboot is needed either way.

## Build

```bash
cd ~/Projects/sound-source-rea/HALPlugin
./build.sh
```

Confirms with `file VolumeControlMicMix.driver/Contents/MacOS/VolumeControlMicMix`
showing a universal (arm64 + x86_64) dylib.

Optional: sanity-check it outside the system daemon first (loads the bundle
in a disposable process and round-trips audio through it — doesn't touch
your system at all):

```bash
clang -framework CoreFoundation -framework CoreAudio -o test_harness src/test_harness.c
./test_harness
```

Should end with `ALL CHECKS PASSED`.

## Install

```bash
sudo mkdir -p /Library/Audio/Plug-Ins/HAL
sudo cp -R VolumeControlMicMix.driver /Library/Audio/Plug-Ins/HAL/
sudo chown -R root:wheel /Library/Audio/Plug-Ins/HAL/VolumeControlMicMix.driver
sudo killall coreaudiod
```

`coreaudiod` restarts itself automatically (it's a launchd daemon) and loads
the new plugin on the way back up. System audio will blip for a moment.

## Verify

```bash
system_profiler SPAudioDataType | grep -A3 "Volume Control Mic Mix"
```

Or open **Audio MIDI Setup.app** (Spotlight it) — "Volume Control Mic Mix"
should appear in the device list on the left, 2 in / 2 out, 48000 Hz.

Then in FaceTime / WhatsApp / Zoom: open its audio/mic settings and pick
"Volume Control Mic Mix" as the input. Until VolumeControl.app is actually
writing into it, the call will just hear silence from it — that's expected
and the next piece to build (the mic+app mixing path inside VolumeControl.app
itself).

## Uninstall

```bash
sudo rm -rf /Library/Audio/Plug-Ins/HAL/VolumeControlMicMix.driver
sudo killall coreaudiod
```

Removes the device entirely; any app that had it selected as input falls
back to its previous/default mic.

## If something looks wrong

- Device doesn't appear after install: re-run `sudo killall coreaudiod`,
  re-check with `system_profiler SPAudioDataType`.
- Any system audio weirdness after install that doesn't resolve: run the
  Uninstall steps above — that always returns the system to its prior state.
- `sudo cp` or `chown` asks for your password — that's macOS gatekeeping
  `/Library`, not this driver doing anything unusual.
