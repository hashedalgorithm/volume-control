# Security Policy

## Reporting a vulnerability

If you find a security issue — especially anything related to:

- the virtual mic device install step (`MicMixInstaller.swift`, which runs
  a shell command with administrator privileges),
- the CoreAudio HAL plugin (`HALPlugin/src/VolumeControlMicMix.c`, which
  runs inside `coreaudiod`), or
- audio capture/mixing paths that could leak or misroute a user's
  microphone or another app's audio,

please report it privately via [GitHub's "Report a vulnerability" flow](../../security/advisories/new)
on this repository rather than opening a public issue, so there's time to
fix it before details are public.

Include, where possible: macOS version, what triggered it, and whether it
needs a specific audio device (Bluetooth, a particular call app, etc.) to
reproduce.

## Scope notes

- The virtual mic device is a single-writer loopback: only this app writes
  to it, and the admin-password install step is a one-time, user-visible
  macOS prompt — it never runs silently. See the "How it works" section of
  [README.md](README.md).
- This project has no network component and sends no data anywhere; all
  processing is local CoreAudio.
