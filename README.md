# BatteryScope

Find out where your Mac's battery actually goes.

macOS tells you a percentage and a vague list of "apps using significant energy."
It won't tell you that Chrome ate 22% of your charge since lunch, that background
indexing cost you more than your editor, or that you lost 9% overnight with the lid
shut. BatteryScope records the data continuously and answers those questions.

## How it works

```
  powermetrics (root)  ─┐
                        ├─→  batteryscoped  ─→  SQLite (WAL)  ─→  BatteryScope.app
  IOKit AppleSmartBattery ┘      sampler          time series        menu bar UI
```

Three sources, joined:

1. **`powermetrics`** — Apple's own diagnostic tool, sampled every 30s for per-process
   *energy impact*. Activity Monitor shows you this number live and then forgets it;
   BatteryScope keeps 30 days of it, so it can integrate over time.
2. **IOKit / AppleSmartBattery** — voltage × amperage, giving the real watts leaving
   the battery, plus cycle count, capacity, and temperature. No root required.
3. **The join** — measured watt-hours from the battery controller, apportioned across
   processes by energy-impact share, rolled up by app and by category (browser,
   terminal, devtools, media, communication, system, background).

## Requirements

macOS 14 or later. Swift toolchain (Xcode command line tools). No external
dependencies — pure SwiftPM against the system SQLite and IOKit.

## Install

Build and install the sampler (needs root, because `powermetrics` does):

```sh
sudo ./Scripts/install-daemon.sh
```

Build and open the menu bar app:

```sh
./Scripts/bundle-app.sh
open dist/BatteryScope.app
```

The app is menu-bar-only (`LSUIElement`), so it shows no Dock icon. It appears in
the menu bar showing your current draw; click it for the full breakdown.

### Without root

The daemon is only needed for *per-process* attribution. Battery-level telemetry
works with no privileges at all:

```sh
swift build
.build/debug/batteryscoped --once          # single sample
.build/debug/batteryscoped --interval 30   # keep sampling
```

Unprivileged runs write to `~/Library/Application Support/BatteryScope/`; the
installed daemon writes to `/Library/Application Support/BatteryScope/`. The app
reads whichever exists, preferring the system one.

## Reading the numbers

Per-app **watt-hours and percentages are estimates, not measurements.** macOS
exposes no per-process wattmeter. What it gives is a unitless "energy impact"
score; BatteryScope splits the *measured* battery discharge across processes in
proportion to that score. The rankings are trustworthy — the magnitudes are
approximate, and the UI marks them with `~`.

Shared costs can't be attributed to the app that caused them. Display backlight
and compositing land under `system` (WindowServer), not on the app that made the
screen bright.

Charging periods and sleep gaps are excluded from drain-rate math rather than
averaged in, which is why the chart draws holes instead of zeros.

## Uninstall

```sh
sudo ./Scripts/uninstall-daemon.sh
```

## Troubleshooting

Daemon log: `/Library/Logs/BatteryScope/daemon.log`

Check whether it's loaded:

```sh
sudo launchctl print system/com.batteryscope.daemon
```

Inspect the database directly:

```sh
sqlite3 "/Library/Application Support/BatteryScope/batteryscope.db" \
  "select count(*) from battery_samples; select count(*) from process_samples;"
```

The app shows its onboarding pane until at least two samples exist — drain rate
needs two points to be a rate. Give the daemon a minute after installing, and
expect per-app attribution to get more useful the longer you run on battery.

## Layout

| Path | What |
|---|---|
| `Sources/BatteryCore/` | Models, SQLite store, process categorizer |
| `Sources/BatteryCore/Analytics/` | Drain series, attribution, health, insights |
| `Sources/batteryscoped/` | The sampler daemon |
| `Sources/BatteryScopeApp/` | SwiftUI menu bar app |
| `Scripts/` | Daemon install/uninstall, app bundling |
