# Contributing

Issues and pull requests are welcome.

## Building

```bash
git clone https://github.com/hashedalgorithm/volume-control.git
cd volume-control
swift build
.build/debug/VolumeControl
```

Or build the full `.app` bundle (also embeds the virtual-mic HAL plugin):

```bash
./Scripts/make_app_bundle.sh
open ~/Applications/VolumeControl.app
```

`./Scripts/relaunch.sh` quits, rebuilds, and relaunches in one step — the
fastest loop for iterating on a running change.

## Reporting bugs

For anything audio-pipeline-related (the process tap code in
`ProcessAudioManager.swift`/`InputMixEngine.swift`, or the HAL plugin in
`HALPlugin/src/VolumeControlMicMix.c`), please include:

- The output/input device type involved (built-in, USB, Bluetooth, HDMI,
  AirPlay) — a lot of the bugs found so far have been device-specific,
  particularly around Bluetooth.
- The macOS version.
- Whether the issue happens with every app or only specific ones.

## Pull requests

- Keep changes focused — one behavior change per PR is easier to review and
  bisect later if something regresses.
- If you're touching the audio pipeline, describe what you tested it with
  (which app, which device, whether a live call was involved) in the PR
  description.
- Match the existing comment style: comments explain *why* a non-obvious
  decision was made, not what the code already says on its face.

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md).
