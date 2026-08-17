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

- An activity timeline: the day in five-minute slices, on one scale, over the
  range the picker actually names — and every slice opens into what was running
  during it, with agent sessions grouped. Replaces a chart that plotted battery
  percentage and watts on one frame with two y-scales, mostly across hours it
  had no data for.
- CPU is now measured as real utilisation from `host_statistics(HOST_CPU_LOAD_INFO)`
  tick counters rather than inferred from the load average, which is a queue
  length and says nothing about work done. It also keeps working on AC, where
  there is no battery discharge to measure at all.
- `Scripts/install-agent.sh` and `uninstall-agent.sh`: a per-user install with no
  root and no password, following the LaunchAgent + login-item pattern. The root
  daemon is now optional and buys exactly one thing — per-app energy attribution.

- Terminal work is attributed to the **tab**, not the terminal. A tab is found
  in the process tree — one `login` + `zsh` per tab — and labelled with the
  folder it is sitting in, which is where the terminal gets its own title, so no
  accessibility or screen-recording permission is involved. Everything spawned
  inside a tab counts toward it, however deep.
- One headline list, "using the most power", replacing the category breakdown,
  top-offenders, agent-session, and drain-chart panels. Rows below a floor are
  dropped: an idle Mac has a hundred processes ticking over at a thousandth of a
  core, and ranking those produces a confident list of `distnoted` and
  `suggestd` that means nothing.
- Diagnosis panels now appear only when there is something to report.
- Helper processes are named after the app the human launched. A row reading
  "Browser Helper (Renderer)" names neither the app nor the page; walking up to
  the process just below `launchd` recovers "Arc", because that is where a
  user-launched app sits. Daemons `launchd` started directly are already their
  own root, and work started in a terminal still belongs to its tab — the walk
  stops at a terminal rather than rolling a tab up into "ghostty".
- Each kept process's ancestors are recorded too, so that walk has a chain to
  follow. They cost nothing and would never survive a top-N cut.

### Removed

- `DrainChartView`, `CategoryBreakdownView`, `TopOffendersView`,
  `ProcessSamplerMissingNotice`, and `ChartData`, all superseded by the single
  power list and the activity timeline.

### Fixed

- Executables installed under a version directory were named after the version.
  Claude Code lives at `~/.local/share/claude/versions/2.1.233`, so `argv[0]`'s
  last component is a version number: it listed as `2.1.233`, which names
  nothing, and kept every Claude Code process out of the agent roster entirely.
  When the last path component says nothing, the name now comes from the first
  segment above it that does.
- **Every CPU figure was about 42x too low.** `proc_taskinfo` reports CPU time
  in mach absolute time units, not nanoseconds, and the two differ by the
  platform timebase — 125/3 on Apple Silicon, 1/1 on Intel, which is why
  assuming nanoseconds looks fine on one and is badly wrong on the other. A
  three-core busy loop measured as 0.02 cores. Caught by running a known load
  and not believing the output.
- A stopped sampler was reported as a stalled machine. Restarting, reinstalling,
  or quitting the app leaves the same hole in the data that a wedged machine
  does, and the clock test could not tell them apart — so every restart claimed
  the Mac had been unresponsive. Each sample now records which sampler *run*
  wrote it (schema v6).
- `launchctl bootout` returns before the service is actually gone, so
  re-installing raced and failed with a bare "Input/output error". The installer
  waits for the old service to disappear.
- The installer's readiness check counted every row in the database, so it
  reported success from a previous install's data while the current one had
  silently failed to start. It now counts only rows written after it began.
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
