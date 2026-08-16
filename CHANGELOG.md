# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## Unreleased

### Added

- Stall diagnosis, a second axis alongside battery drain: `pressure_samples`
  records memory pressure, swap, page-ins, load average, and thermal throttling
  every tick, and `StallAnalyzer` turns stretches of it into episodes with a
  cause and a severity. A Mac can hang badly on AC power while the battery is
  untouched, so this is measured in its own right rather than inferred from watts.
- Coding-agent sessions, grouped by process ancestry: an orchestrator plus every
  agent, helper, and compiler beneath it collapses into one row, so eight
  `claude` processes read as "one Rudder session running eight agents, holding
  11 GB". An agent with no orchestrator ancestor roots its own session.
  Recognizes `claude`, `codex`, `aider`, `goose`, `opencode`, `amp`,
  `cursor-agent`, `gemini`, `copilot`, `crush`, and `droid` under `rudder`,
  `conductor`, `crystal`, `sculptor`, or `vibe-kanban`.
- Stalls are attributed to the sessions that were resident through them, in
  correlational wording ("was running", never "caused"), and only when a session
  held a substantial share of the machine — a stall caused by something else is
  reported with no culprit rather than blamed on whichever agent was running.
- Two insight rules: one for stalls, one warning when agent sessions hold a large
  share of memory before anything has stalled yet.
- `System pressure` and `Agent sessions` panels in the popover, placed above the
  battery attribution — when a Mac is stalling, that is the question being asked.
- Agent sampling works with no privileges. Ancestry, resident memory, and CPU
  time come from the process table rather than `powermetrics`, so stall
  attribution does not wait for the root daemon to be installed. Costs about 4 ms
  per 30-second tick.
- The machine's heaviest processes by memory, CPU, and disk are recorded
  alongside the agent sessions, so a stall caused by Spotlight, Time Machine, or
  a runaway browser is named rather than reported with no culprit. An agent
  session still outranks a lone process as the thing to blame, because a session
  is the more actionable unit.
- Per-process and system-wide disk I/O, via `proc_pid_rusage` and
  `IOBlockStorageDriver`. Disk stalls are a common reason a Mac feels frozen and
  were invisible in every other signal here — a process can pin the machine
  while using little CPU and no unusual memory.
- Pressure is now sampled every **5 seconds** rather than every 30, with the
  process table still read every 30. A twenty-second stall used to fall entirely
  between two samples; the minimum recordable episode drops from 45 s to 15 s.
- Sampler starvation is treated as evidence. When the daemon cannot get
  scheduled for several intervals while the monotonic clock keeps pace with the
  wall clock, the machine was awake and unable to spare four milliseconds — that
  gap is recorded as a critical stall spanning the hole itself. Sleep leaves the
  same hole and is excluded by comparing the two clocks.
- `ppid` and `resident_bytes` on `process_samples`, a `tracked_samples` table,
  and uptime/disk/interval columns on `pressure_samples` (schema v3 through v5).
  All migrate in place, and an app built against the new schema reads an older
  daemon's database without error — it simply has less to say.

### Fixed

- Process names are read from `argv[0]` rather than the kernel's `p_comm`, which
  reports the interpreter and truncates at 16 characters. Every coding agent
  shipped as a Node script was showing up as `node`, and so was invisible to the
  grouping.
- `proc_pid_rusage` was called with the address of a lone pointer variable, as
  its Swift signature invites, handing the kernel eight bytes to write several
  hundred into. It trapped on the first call; the struct is now allocated by the
  caller, which is what the C API actually asks for.

## 1.0.0 — 2026-08-16

Initial release.

### Added

- `batteryscoped`, a root LaunchDaemon sampler joining `powermetrics` per-process
  energy impact with IOKit/AppleSmartBattery watts, cycle count, capacity, and
  temperature into a WAL-mode SQLite database, sampled continuously.
- `BatteryScope.app`, a menu-bar-only (`LSUIElement`) SwiftUI app showing current
  draw at a glance and, on click, a drain chart, top-offending processes and
  categories, battery health, and a set of ranked insights (heavy process, heavy
  category, drain-rate trend, sleep drain, high drain rate, battery health,
  browser-vs-terminal, mostly-plugged-in). Onboarding until at least two samples
  exist.
- Process categorization into browser, terminal, devtools, media, communication,
  system, and background, with helper-process merging (e.g. renderer/GPU helpers
  folded into their parent app) for attribution.
- Per-app watt-hour and percentage estimates, apportioning measured battery
  discharge across processes by energy-impact share and labeled as estimates
  throughout the UI, since macOS exposes no per-process wattmeter.
- Drain-rate math that excludes charging periods and sleep gaps rather than
  averaging over them, drawing chart holes instead of misleading zeros.
- `Scripts/install-daemon.sh` / `Scripts/uninstall-daemon.sh` to install and
  remove the LaunchDaemon, its log rotation config, and its data; `--purge`
  deletes the collected database, which is otherwise kept across uninstalls.
- `Scripts/bundle-app.sh` to build and assemble `dist/BatteryScope.app`,
  ad-hoc signed.
- `Scripts/make-icon.swift` and `Resources/AppIcon.icns`, a generated app icon:
  a battery divided into proportional segments, echoing the breakdown the app
  itself shows.
- Log rotation for `/Library/Logs/BatteryScope/daemon.log` via a `newsyslog.d`
  drop-in installed alongside the daemon.
- No external dependencies — pure SwiftPM against the system SQLite and IOKit,
  macOS 14+.
