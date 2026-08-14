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
        guard !inFlight else { return }
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
            return .ready(Snapshot(
                report: report,
                latest: latest,
                databasePath: path,
                generatedAt: now
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
    private nonisolated static func sampleCount(analytics: Analytics, now: Date) throws -> Int {
        let recent = try analytics.store.batterySamples(from: now.addingTimeInterval(-3600), to: now)
        if recent.count >= 2 { return recent.count }
        return try analytics.store.batterySamples(from: now.addingTimeInterval(-7 * 86_400), to: now).count
    }
}
