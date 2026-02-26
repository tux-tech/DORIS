<p align="center">
  <img src="doris.png" alt="D.O.R.I.S. Logo" width="900">
</p>
# D.O.R.I.S.

## DOS Operational Runtime Invocation Service

A Debian-based DOS desktop environment that treats DOS applications as
discrete runtime invocations --- not as one giant emulation session.

------------------------------------------------------------------------

## Overview

D.O.R.I.S. provisions:

-   XLibre (X11 server, no Wayland)
-   i3 window manager
-   dosemu2 (KVM-accelerated where available)
-   A shared, structured D: drive
-   A binary classifier for legacy executables
-   Desktop integration and launcher tooling

The result: a minimal, reproducible DOS runtime layer on modern Linux.

------------------------------------------------------------------------

# Architecture Overview

D.O.R.I.S. is not "run DOS inside a window."

It is:

-   A dedicated X11 stack (XLibre)
-   A tiling WM (i3) configured for floating 800×600 DOS sessions
-   A structured dosemu2 environment
-   A runtime invocation model via `dos_launcher.sh`

Each launched application:

-   Runs in its own dosemu2 process\
-   Mounts a shared D: drive\
-   Is isolated at process level\
-   Can be invoked via CLI or desktop shortcut

You are not entering a monolithic DOS session.\
You are invoking a DOS runtime instance.

------------------------------------------------------------------------

# Why XLibre Instead of Wayland?

X11 is effectively legacy.\
Wayland is fragmented and painful for this use case.

dosemu2 is historically and operationally X11-native. Wayland
introduces:

-   XWayland translation layers
-   Input quirks
-   Window sizing issues
-   Grabbing/clipboard inconsistencies
-   Compositor dependencies

For deterministic, low-level DOS graphics behavior, direct X11 is still
the most stable path.

XLibre makes sense because:

-   It is a maintained fork of the traditional X server
-   It avoids dragging in Wayland and compositor stacks
-   It keeps the display path simple
-   It behaves predictably for legacy software

D.O.R.I.S. explicitly does not install:

-   Wayland
-   XWayland
-   Mutter
-   Weston

The stack remains intentionally narrow.

If XLibre packages are unavailable for your Debian codename, the
installer falls back to `xserver-xorg` --- but the system remains
XLibre-ready.

------------------------------------------------------------------------

# What the Installer Actually Sets Up

## Display Layer

-   XLibre (or xorg fallback)
-   xinit
-   Auto-login on tty1
-   Auto-start `startx`
-   i3 window manager
-   PCManFM desktop

## Window Behavior

-   dosemu windows float
-   Default size: 800×600
-   No forced fullscreen
-   Mouse grab disabled

## DOS Environment

-   dosemu2 (apt or source build)
-   KVM acceleration (if available)

Structured drive layout:

    ~/dos_env/
      drive_d/
        APPS/
        GAMES/
        UTILS/
        WORK/
        DOCS/
      drive_c_template/

All runtime instances share D:.

------------------------------------------------------------------------

# Runtime Tooling

## `dos_launcher.sh`

Launch a DOS app in a new window.

## `dos_identify.sh`

Binary classifier that detects:

-   DOS MZ EXE
-   COM (with heuristics)
-   BAT
-   Windows PE (blocked)
-   NE / LE / LX (blocked)
-   CP/M-80 (blocked)

Prevents accidentally launching PE binaries in dosemu2.

## `dos_scan_apps.sh`

Scans D: drive.\
Creates desktop shortcuts only for runnable DOS binaries.

## `dos_add_app.sh`

Create a single shortcut manually.

------------------------------------------------------------------------

# Installation

**Target:** Clean Debian 13\
(Trixie recommended, Bookworm supported)

1.  Install minimal Debian (no desktop environment).
2.  SSH in.
3.  Run:

``` bash
sudo bash install.sh
```

4.  Reboot.

System boots directly into:

    tty1 → autologin → startx → XLibre → i3 → PCManFM

------------------------------------------------------------------------

# Current Limitations

This is intentionally minimal and pragmatic.

What it does NOT yet include:

-   SoundBlaster / audio configuration enabled
-   MIDI routing
-   Network stack inside DOS
-   Preinstalled FreeDOS utilities
-   Package management for DOS apps
-   Snapshot/rollback per runtime instance
-   Per-app resource profiles
-   Automated icon extraction from EXE files
-   Integration with Wine for hybrid workflows
-   Session manager beyond i3

Also:

-   COM file detection is heuristic.
-   Some NE/DPMI programs may partially work but are blocked.
-   No GPU passthrough tuning for heavy DOS graphics workloads.
-   No multi-user isolation model beyond Linux user boundaries.

------------------------------------------------------------------------

# What Would Make It More Full-Featured

## 1. Runtime Profiles

Per-app configuration:

-   Memory (XMS/EMS tuning)
-   CPU mode
-   Sound on/off
-   Window geometry

## 2. Sound Support

Enable:

-   SoundBlaster emulation
-   ALSA routing
-   MIDI via Fluidsynth

## 3. DOS Package Registry

A manifest system:

-   YAML/JSON app descriptors
-   Versioned installs
-   Metadata
-   Automatic shortcut + icon generation

## 4. Sandboxed C: Per Invocation

Currently D: is shared and C: is static.

Possible improvements:

-   Clone a clean C: template per launch
-   Enable ephemeral C: drives

## 5. CP/M Mode

Integrate RunCPM for 8080/Z80 binaries instead of blocking them.

## 6. Multi-Seat / Multi-User Support

Make it deployable as a lab environment.

## 7. Headless Invocation Mode

Allow CLI-only runtime invocation without starting X.

------------------------------------------------------------------------

# Intended Use Cases

-   Running legacy engineering tools
-   Retro development (Turbo C, Pascal, etc.)
-   Archival software access
-   Structured DOS runtime experimentation
-   People who enjoy reducing chaos in old software stacks

This is not a nostalgia toy.\
It is an intentionally constrained runtime layer.

------------------------------------------------------------------------

# Philosophy

Modern Linux stacks are complex.\
Legacy software stacks are fragile.

D.O.R.I.S. narrows the surface area:

-   One display server
-   One WM
-   One emulator
-   One shared drive model
-   Clear binary validation

Minimal moving parts.\
Predictable behavior.\
Repeatable installs.

Is it broadly necessary?\
Probably not.

Is it clean?\
Yes.

And that's the point.
