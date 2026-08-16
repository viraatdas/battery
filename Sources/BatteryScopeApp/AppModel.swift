import BatteryCore
import Combine
import Foundation

/// The window the popover is currently showing.
enum WindowChoice: String, CaseIterable, Identifiable, Sendable {
    case lastHour = "1h"
    case last6Hours = "6h"
    case last24Hours = "24h"
    case last7Days = "7d"

    var id: String { rawValue }

    var title: String { rawValue }

    var longTitle: String {
        switch self {
        case .lastHour: return "the last hour"
        case .last6Hours: return "the last 6 hours"
        case .last24Hours: return "the last 24 hours"
        case .last7Days: return "the last 7 days"
        }
    }

    func window(ending end: Date) -> TimeWindow {
        switch self {
        case .lastHour: return .lastHour(ending: end)
        case .last6Hours: return .last6Hours(ending: end)
        case .last24Hours: return .last24Hours(ending: end)
        case .last7Days: return .last7Days(ending: end)
        }
    }
}

/// Why the app is showing onboarding instead of data.
enum OnboardingReason: Sendable, Equatable {
    /// Neither the system nor the per-user database exists.
    case noDatabase
    /// The database is there but has not accumulated enough to say anything.
    case tooFewSamples(Int)
}

/// Everything one refresh produced.
struct Snapshot: Sendable {
    var report: AnalyticsReport
    /// The most recent battery reading, used for the menu bar and the header.
    /// Fresher than `report.health`, which is a median over a lookback window.
    var latest: BatterySample?
    var databasePath: String
    var generatedAt: Date
    /// Whether the database has ever recorded a single process sample, as
    /// opposed to `report.processes` simply being empty for this window.
    ///
    /// Per-process attribution needs the root sampler daemon (powermetrics
    /// needs root); a plain `batteryscoped` run only ever writes battery
    /// samples. The per-app panels use this to tell "the daemon has never
    /// run" apart from "nothing used power in this window" — the first is a
    /// setup step, the second is just a quiet window.
    var hasEverRecordedProcessSamples: Bool

    /// Seconds between the newest sample and when this snapshot was taken.
    var sampleAge: TimeInterval? {
        latest.map { generatedAt.timeIntervalSince(Date(timeIntervalSince1970: Double($0.timestampMs) / 1000)) }
    }
}

enum LoadOutcome: Sendable {
    case ready(Snapshot)
    case onboarding(OnboardingReason)
    /// The database exists but could not be read. Shown, never crashed on.
    case failure(String)
}

/// Owns the refresh loop and the one piece of state the whole interface reads.
///
/// The store is opened read-only, fresh, on every refresh: the sampler writes in
/// WAL mode so a reader can never block or corrupt it, and reopening means the
/// app recovers on its own if the daemon is installed while it is running.
@MainActor
final class AppModel: ObservableObject {

    /// Roughly the sampler's own cadence. Fast enough that the menu bar is
    /// honest, slow enough that a laptop does not pay for its own battery UI.
    static let refreshInterval: TimeInterval = 15

    @Published private(set) var outcome: LoadOutcome = .onboarding(.noDatabase)
    @Published private(set) var isRefreshing = false
    @Published var choice: WindowChoice = .last6Hours {
        didSet { if oldValue != choice { refresh() } }
    }
    @Published var metric: ChartData.Metric = .watts

    private var timer: Timer?
    private var inFlight = false
    /// Set when `choice` changes while a load is already running, so the stale
    /// in-flight result is not the last word — the completion kicks off one
    /// more refresh for whatever `choice` is by the time it lands.
    private var refreshPending = false

    init(startTimer: Bool = true) {
        guard startTimer else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit { timer?.invalidate() }

    /// Current snapshot, if the last refresh produced one.
    var snapshot: Snapshot? {
        if case .ready(let snapshot) = outcome { return snapshot }
        return nil
    }

    func refresh() {
        guard !inFlight else {
            // A window change (or another refresh() call) arrived mid-load.
            // The result in flight is for the choice that was current when it
            // started, which may not be current any more — queue one more
            // refresh rather than let this request vanish silently.
            refreshPending = true
            return
        }
        inFlight = true
        isRefreshing = true
        let choice = self.choice
        let now = Date()
        Task.detached(priority: .utility) {
            let result = AppModel.load(choice: choice, now: now)
            await MainActor.run {
                self.outcome = result
                self.inFlight = false
                self.isRefreshing = false
                if self.refreshPending {
                    self.refreshPending = false
                    self.refresh()
                }
            }
        }
    }

    /// Injects an outcome without going through the refresh loop. Used by the
    /// offscreen self-test so it can render a known state.
    func applyForTesting(_ outcome: LoadOutcome) {
        self.outcome = outcome
    }

    // MARK: - Loading

    /// Pure, off the main actor, and total: every failure path returns a value.
    /// A missing database is the normal first-run state, not an error.
    nonisolated static func load(choice: WindowChoice, now: Date) -> LoadOutcome {
        guard let path = DBLocation.existingPath() else { return .onboarding(.noDatabase) }
        do {
            let analytics = try Analytics(readOnlyPath: path)

            // Cheap liveness check first: a fresh database with one row cannot
            // support any of the rate math, and an empty chart explains nothing.
            let count = try sampleCount(analytics: analytics, now: now)
            guard count >= 2 else { return .onboarding(.tooFewSamples(count)) }

            let report = try analytics.report(window: choice.window(ending: now), processLimit: 12)
            let latest = try analytics.store.latestBatterySample(asOf: now, lookback: 7 * 86_400)

            // The common case — the sampler is installed and this window has
            // process rows — never pays for the extra query below: it only
            // runs to disambiguate an empty `report.processes`.
            let everRecordedProcessSamples = try report.processes.isEmpty
                ? hasAnyProcessSamplesEver(analytics: analytics)
                : true

            return .ready(Snapshot(
                report: report,
                latest: latest,
                databasePath: path,
                generatedAt: now,
                hasEverRecordedProcessSamples: everRecordedProcessSamples
            ))
        } catch {
            return .failure(summarize(error))
        }
    }

    /// SQLite errors arrive with the whole failing statement attached. The panel
    /// wants the reason, not the query.
    private nonisolated static func summarize(_ error: Error) -> String {
        let text = String(describing: error)
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        return firstLine.count > 160 ? String(firstLine.prefix(160)) + "…" : firstLine
    }

    /// Counts recent samples, widening the search only when the recent past is
    /// empty, so the steady-state refresh stays a small read.
    ///
    /// Safe to materialize in full even at its widest (7-day) probe: unlike
    /// `process_samples` below, `battery_samples` has exactly one row per
    /// sample tick — no per-process fan-out — so even a week of them is at
    /// most a few tens of thousands of rows.
    private nonisolated static func sampleCount(analytics: Analytics, now: Date) throws -> Int {
        let recent = try analytics.store.batterySamples(from: now.addingTimeInterval(-3600), to: now)
        if recent.count >= 2 { return recent.count }
        return try analytics.store.batterySamples(from: now.addingTimeInterval(-7 * 86_400), to: now).count
    }

    /// Whether the database has ever recorded a process sample, independent
    /// of the currently selected window.
    ///
    /// One `SELECT 1 ... LIMIT 1` via `SQLiteStore.hasAnyProcessSamples()`.
    /// It has to be an existence query rather than a range fetch, because
    /// `process_samples` gets one row *per running task per sample tick* —
    /// at the default 30s interval, ~700 processes on an active machine, and
    /// 30 days of retention, the full table is on the order of tens of
    /// millions of rows. Earlier versions of this function fetched rows and
    /// checked `isEmpty`, which decodes every matching row into a
    /// `[ProcessSample]` first; do not go back to that.
    private nonisolated static func hasAnyProcessSamplesEver(analytics: Analytics) throws -> Bool {
        try analytics.store.hasAnyProcessSamples()
    }
}
