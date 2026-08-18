# BatteryScope

**[battery.viraat.dev](https://battery.viraat.dev)** &nbsp;·&nbsp; [**Download for macOS**](https://github.com/viraatdas/battery/releases/latest) — signed and notarized

Find out where your Mac's battery — and its responsiveness — actually goes.

macOS tells you a percentage and a vague list of "apps using significant energy."
It won't tell you that Chrome ate 22% of your charge since lunch, that background
indexing cost you more than your editor, or that you lost 9% overnight with the lid
shut. And when the machine locks up for four minutes, it leaves behind no record
at all of what was resident when it happened. BatteryScope records both,
continuously, and answers those questions.

## How it works

```
  powermetrics (root)  ─┐
                        ├─→  batteryscoped  ─→  SQLite (WAL)  ─→  BatteryScope.app
  IOKit AppleSmartBattery ┤      sampler          time series        menu bar UI
                        │
  process table + VM stats ┘
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

Plus a second, separate axis — why the machine *stalls*, which is not the same
question as where the battery went. A Mac pinned at full load on AC power hangs
badly while drawing nothing from the battery at all:

4. **Process table + VM statistics + IOKit** — memory pressure, swap, page-ins,
   load average, thermal throttling, and disk throughput, sampled every **5
   seconds**. None of it needs root.

Detection and attribution run at different cadences on purpose. Pressure is
cheap and small, so it is read every 5 s and a twenty-second stall still leaves
a trace. The process table is neither, so it is read every 30 s — which is fine,
because a process holding 12 GB does not appear and vanish inside half a minute.

Alongside every agent session, the sampler keeps the machine's heaviest few
processes by memory, CPU, and disk, whoever they belong to. That is what lets a
stall be pinned on Spotlight or Time Machine rather than reported with no
culprit at all.

### When the sampler itself can't run

The strongest signal is the one that comes from *missing* data. This daemon
needs about four milliseconds of CPU per tick; a Mac that could not spare it for
ninety seconds was not slow, it was wedged. Those holes are detected and
reported as stalls in their own right.

Sleep leaves an identical hole. The two are told apart by the monotonic clock,
recorded next to the wall clock in every sample: through a hang it advances with
the wall clock, through sleep it falls well behind.

## Coding agents

Running several coding agents at once is the fastest way to wedge a Mac, and the
hardest to see: every per-process view shows an undifferentiated pile of
identical `claude` rows with nothing tying them together.

BatteryScope groups them by process ancestry. An agent process is walked up its
parent chain; if an orchestrator is found, that orchestrator becomes the session
root and the session is everything beneath it — the agents, their helpers, and
the compilers and test runners *they* spawn. So eight `claude` processes read as
**one Rudder session running eight agents, holding 11 GB**, which is the form the
question actually gets asked in.

When the machine then stalls, the stall is recorded with whatever sessions were
resident through it:

> **Your Mac stalled for 4m.** The worst was at 10:11 PM — memory pressure and
> swap thrash. Rudder was running 6 agents, holding 11.0 GB (46% of memory).
> Swap grew 3.0 GB.

Attribution is correlational and the wording says so: a session holding memory
during a stall is evidence, not proof. A session is named only when it held a
substantial share of the machine, so a stall caused by something else is reported
as a stall with no culprit rather than blamed on whichever agent was running.

Recognized out of the box: `claude`, `codex`, `aider`, `goose`, `opencode`,
`amp`, `cursor-agent`, `gemini`, `copilot`, `crush`, `droid`, orchestrated by
`rudder`, `conductor`, `crystal`, `sculptor`, or `vibe-kanban` — and an agent
started by hand in a terminal roots a session of its own. Processes are matched
on `argv[0]` rather than the kernel's `p_comm`, because a tool shipped as a Node
script reports as `node` there and would otherwise be invisible.

## Requirements

macOS 14 or later. Swift toolchain (Xcode command line tools). No external
dependencies — pure SwiftPM against the system SQLite and IOKit.

## What you see

One list: **what is using the most power**, in order.

The thing that makes it useful is that terminal work is named by *tab*, not by
terminal. "Ghostty — 41%" is useless with eight tabs open. This says:

```
battery      rudder-native      44%
mwitch       claude             22%
Arc                             14%
```

A tab is a real object in the process tree — the terminal spawns one `login` and
`zsh` per tab — so it can be found without the accessibility API, without screen
recording permission, and without asking the terminal anything. The label is the
folder the tab is sitting in, which is also where the terminal gets the title it
shows you. Everything spawned inside the tab, however deep, counts toward it.

Everything else is named after **the app you launched**, not the helper doing the
work: an Arc renderer is walked up to `Arc`, because the process just below
`launchd` is what a person actually started. "Browser Helper (Renderer)" answers
no question worth asking.

Below that, the day in **five-minute slices**. Click any one and it opens: what
was running during those five minutes. Slices where the machine stalled are red.

Diagnosis panels — pressure, stalls, insights — only appear when there is
something wrong to report. A panel permanently saying "nothing is wrong" is
clutter.

## Install

Download the [notarized DMG](https://github.com/viraatdas/battery/releases/latest),
drag BatteryScope to Applications, and open it. It lives in the menu bar — no
Dock icon.

To keep it sampling in the background and start at login — no root, no password.
Installs a LaunchAgent in your own login session and adds the menu bar app as a
login item:

```sh
./Scripts/install-agent.sh
```

That gives you everything except per-app *energy* attribution, which needs
`powermetrics` and therefore root. To add it:

```sh
sudo ./Scripts/install-daemon.sh
```

The installer polls for the daemon to actually come up before printing success
and prints the log tail if it doesn't, builds and installs a `newsyslog.d` drop-in
so `daemon.log` rotates instead of growing forever, and fixes up permissions on
any existing database sidecar files so the app can read them.

Build and open the menu bar app:

```sh
./Scripts/bundle-app.sh
open dist/BatteryScope.app
```

The app is menu-bar-only (`LSUIElement`), so it shows no Dock icon. It appears in
the menu bar showing your current draw; click it for the full breakdown.

### Without root

The daemon is only needed for *per-process energy* attribution, because
`powermetrics` needs root. Battery telemetry, system pressure, and agent-session
grouping all work with no privileges at all — ancestry, resident memory, and CPU
time come from the process table, which any user can read. So the question "which
session was holding the machine when it froze" does not wait for anyone to
install a daemon:

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

## Limitations

Everything before the daemon was installed is invisible — there's no retroactive
history, and no sync across machines: each Mac keeps its own local database.
Per-process attribution needs the root daemon; without it you only get
battery-level telemetry. Running `powermetrics` continuously costs a small
amount of power itself, which is included in what gets measured but is worth
knowing about if you're chasing the last percent.

## Uninstall

```sh
./Scripts/uninstall-agent.sh              # the per-user agent
sudo ./Scripts/uninstall-daemon.sh        # the root daemon, if installed
```

Both keep the collected database, which is the only copy of your machine's
history. Pass `--purge` to delete it.

## Troubleshooting

Daemon log: `/Library/Logs/BatteryScope/daemon.log`

Check whether it's loaded:

```sh
sudo launchctl print system/com.batteryscope.daemon
```

Inspect the database directly:

```sh
sqlite3 "/Library/Application Support/BatteryScope/batteryscope.db" \
  "select count(*) from battery_samples; select count(*) from process_samples;
   select count(*) from pressure_samples; select count(*) from agent_samples;"
```

See which agent sessions are being recorded right now:

```sh
sqlite3 "/Library/Application Support/BatteryScope/batteryscope.db" \
  "select name, ppid, resident_bytes/1048576 as mb, round(cpu_ms_per_s/1000, 2) as cores
   from agent_samples where timestamp_ms = (select max(timestamp_ms) from agent_samples)
   order by mb desc;"
```

The app shows its onboarding pane until at least two samples exist — drain rate
needs two points to be a rate. Give the daemon a minute after installing, and
expect per-app attribution to get more useful the longer you run on battery.

## Layout

| Path | What |
|---|---|
| `Sources/BatteryCore/` | Models, SQLite store, process categorizer |
| `Sources/BatteryCore/Analytics/` | Drain series, attribution, health, insights, agent sessions, stalls |
| `Sources/batteryscoped/` | The sampler daemon |
| `Sources/BatteryScopeApp/` | SwiftUI menu bar app |
| `Resources/` | LaunchDaemon plist, log rotation config, app icon |
| `Scripts/` | Daemon install/uninstall, app bundling, icon generation |

## License

MIT. See [LICENSE](LICENSE).
