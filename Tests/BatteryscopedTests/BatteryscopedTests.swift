import BatteryCore
import XCTest

@testable import batteryscoped

final class ConfigurationTests: XCTestCase {

    private let fallbackDB = "/tmp/batteryscope-tests-default.db"

    private func parse(_ arguments: [String]) throws -> Configuration {
        try Configuration.parse(arguments: arguments, defaultDatabasePath: fallbackDB)
    }

    func testDefaults() throws {
        let configuration = try parse([])
        XCTAssertEqual(configuration.intervalSeconds, 30)
        XCTAssertEqual(configuration.databasePath, fallbackDB)
        XCTAssertFalse(configuration.runOnce)
        XCTAssertFalse(configuration.showHelp)
    }

    func testAllFlagsTogether() throws {
        let configuration = try parse(["--interval", "5.5", "--db", "/tmp/x.db", "--once"])
        XCTAssertEqual(configuration.intervalSeconds, 5.5)
        XCTAssertEqual(configuration.databasePath, "/tmp/x.db")
        XCTAssertTrue(configuration.runOnce)
    }

    func testHelpFlags() throws {
        XCTAssertTrue(try parse(["--help"]).showHelp)
        XCTAssertTrue(try parse(["-h"]).showHelp)
    }

    func testRejectsNonPositiveOrUnparseableInterval() {
        for value in ["0", "-3", "abc", "nan"] {
            XCTAssertThrowsError(try parse(["--interval", value]), "interval '\(value)'")
        }
    }

    func testRejectsMissingValues() {
        XCTAssertThrowsError(try parse(["--interval"]))
        XCTAssertThrowsError(try parse(["--db"]))
    }

    func testRejectsUnknownFlag() {
        XCTAssertThrowsError(try parse(["--nope"])) { error in
            guard case Configuration.ParseError.unknownFlag(let flag) = error else {
                return XCTFail("expected .unknownFlag, got \(error)")
            }
            XCTAssertEqual(flag, "--nope")
        }
    }

    func testUsageMentionsEveryFlag() {
        let usage = Configuration.usage(defaultDatabasePath: fallbackDB)
        for flag in ["--interval", "--db", "--once", "--help"] {
            XCTAssertTrue(usage.contains(flag), "usage is missing \(flag)")
        }
        XCTAssertTrue(usage.contains("install-daemon.sh"))
    }
}

final class BatteryReaderConversionTests: XCTestCase {

    private let timestamp: Int64 = 1_700_000_000_000

    // MARK: - Percent

    func testPercentFromMatchingMilliampHours() {
        XCTAssertEqual(
            BatteryReader.derivePercent(currentCapacity: 4000, maxCapacity: 8000),
            50,
            accuracy: 0.0001
        )
    }

    func testPercentWhenBothReportedAsPercentages() {
        // The common Apple silicon shape: CurrentCapacity=73, MaxCapacity=100.
        XCTAssertEqual(
            BatteryReader.derivePercent(currentCapacity: 73, maxCapacity: 100),
            73,
            accuracy: 0.0001
        )
    }

    func testPercentWithMixedUnitsPrefersRawPair() {
        // CurrentCapacity is a percentage while MaxCapacity is mAh: the ratio
        // would be nonsense, so the raw mAh pair wins.
        XCTAssertEqual(
            BatteryReader.derivePercent(
                currentCapacity: 88,
                maxCapacity: 8000,
                rawCurrentCapacity: 6000,
                rawMaxCapacity: 8000
            ),
            75,
            accuracy: 0.0001
        )
    }

    func testPercentWithMixedUnitsAndNoRawPairTrustsPercentage() {
        XCTAssertEqual(
            BatteryReader.derivePercent(currentCapacity: 88, maxCapacity: 8000),
            88,
            accuracy: 0.0001
        )
    }

    func testPercentIsClampedAndSurvivesZeroMax() {
        XCTAssertEqual(BatteryReader.derivePercent(currentCapacity: 9000, maxCapacity: 8000), 100)
        XCTAssertEqual(BatteryReader.derivePercent(currentCapacity: -5, maxCapacity: 100), 0)
        XCTAssertEqual(BatteryReader.derivePercent(currentCapacity: 42, maxCapacity: 0), 42)
    }

    // MARK: - Health

    func testMaxCapacityPctFromMilliampHours() {
        XCTAssertEqual(
            BatteryReader.deriveMaxCapacityPct(
                maxCapacity: 8000,
                rawMaxCapacity: nil,
                nominalCapacity: nil,
                designCapacity: 10000
            ),
            80,
            accuracy: 0.0001
        )
    }

    func testMaxCapacityPctFallsBackToRawWhenPercentShaped() {
        // MaxCapacity=100 is a percentage, so health comes from the raw mAh.
        XCTAssertEqual(
            BatteryReader.deriveMaxCapacityPct(
                maxCapacity: 100,
                rawMaxCapacity: 8000,
                nominalCapacity: 8244,
                designCapacity: 8579
            ),
            8000.0 / 8579.0 * 100,
            accuracy: 0.0001
        )
    }

    func testMaxCapacityPctWithoutDesignCapacity() {
        XCTAssertEqual(
            BatteryReader.deriveMaxCapacityPct(
                maxCapacity: 93,
                rawMaxCapacity: nil,
                nominalCapacity: nil,
                designCapacity: 0
            ),
            93,
            accuracy: 0.0001
        )
    }

    // MARK: - Watts

    func testWattsAreNegativeWhileDischarging() {
        let watts = BatteryReader.watts(voltageMv: 12000, amperageMa: -2500)
        XCTAssertEqual(watts, -30, accuracy: 0.0001)
    }

    func testWattsArePositiveWhileCharging() {
        XCTAssertEqual(BatteryReader.watts(voltageMv: 12000, amperageMa: 2500), 30, accuracy: 0.0001)
    }

    // MARK: - Temperature

    func testTemperatureCentiDegrees() {
        // 3034 → 30.34 °C, the shape Apple silicon reports.
        let celsius = try? XCTUnwrap(BatteryReader.normalizeTemperature(3034))
        XCTAssertEqual(celsius ?? 0, 30.34, accuracy: 0.01)
    }

    func testTemperatureDeciDegrees() {
        let celsius = try? XCTUnwrap(BatteryReader.normalizeTemperature(304))
        XCTAssertEqual(celsius ?? 0, 30.4, accuracy: 0.01)
    }

    func testTemperatureRejectsNilZeroAndNonsense() {
        XCTAssertNil(BatteryReader.normalizeTemperature(nil))
        XCTAssertNil(BatteryReader.normalizeTemperature(0))
        XCTAssertNil(BatteryReader.normalizeTemperature(999_999))
    }

    // MARK: - Whole-sample conversion

    func testSampleFromRealisticRegistryDictionary() {
        // Values lifted from a real MacBook Pro AppleSmartBattery node.
        let properties: [String: Any] = [
            "CurrentCapacity": 100,
            "MaxCapacity": 100,
            "DesignCapacity": 8579,
            "AppleRawCurrentCapacity": 8000,
            "AppleRawMaxCapacity": 8000,
            "NominalChargeCapacity": 8244,
            "Voltage": 12988,
            "Amperage": 0,
            "InstantAmperage": 0,
            "CycleCount": 154,
            "IsCharging": false,
            "ExternalConnected": true,
            "Temperature": 3034,
        ]
        let sample = BatteryReader.sample(from: properties, timestampMs: timestamp)

        XCTAssertEqual(sample.timestampMs, timestamp)
        XCTAssertEqual(sample.percent, 100, accuracy: 0.0001)
        XCTAssertFalse(sample.isCharging)
        XCTAssertTrue(sample.externalPower)
        XCTAssertEqual(sample.voltageMv, 12988)
        XCTAssertEqual(sample.amperageMa, 0)
        XCTAssertEqual(sample.wattsDrawn, 0, accuracy: 0.0001)
        XCTAssertEqual(sample.cycleCount, 154)
        XCTAssertEqual(sample.maxCapacityPct, 8000.0 / 8579.0 * 100, accuracy: 0.0001)
        XCTAssertEqual(sample.temperatureC ?? 0, 30.34, accuracy: 0.01)
    }

    func testSampleWhileDischargingProducesNegativeWatts() {
        let properties: [String: Any] = [
            "CurrentCapacity": 6000,
            "MaxCapacity": 8000,
            "DesignCapacity": 8579,
            "Voltage": 11800,
            "InstantAmperage": -1850,
            "Amperage": -1700,
            "CycleCount": 154,
            "IsCharging": false,
            "ExternalConnected": false,
        ]
        let sample = BatteryReader.sample(from: properties, timestampMs: timestamp)

        XCTAssertEqual(sample.percent, 75, accuracy: 0.0001)
        XCTAssertFalse(sample.externalPower)
        // InstantAmperage wins over the averaged Amperage.
        XCTAssertEqual(sample.amperageMa, -1850)
        XCTAssertEqual(sample.wattsDrawn, 11.8 * -1.85, accuracy: 0.0001)
        XCTAssertLessThan(sample.wattsDrawn, 0)
        XCTAssertNil(sample.temperatureC)
    }

    func testSampleFallsBackToAveragedAmperageWhenInstantIsZero() {
        let properties: [String: Any] = [
            "CurrentCapacity": 50,
            "MaxCapacity": 100,
            "Voltage": 12000,
            "InstantAmperage": 0,
            "Amperage": -1000,
        ]
        let sample = BatteryReader.sample(from: properties, timestampMs: timestamp)
        XCTAssertEqual(sample.amperageMa, -1000)
        XCTAssertEqual(sample.wattsDrawn, -12, accuracy: 0.0001)
    }

    func testSampleFromEmptyDictionaryDoesNotCrash() {
        let sample = BatteryReader.sample(from: [:], timestampMs: timestamp)
        XCTAssertEqual(sample.percent, 0)
        XCTAssertEqual(sample.wattsDrawn, 0)
        XCTAssertEqual(sample.voltageMv, 0)
        XCTAssertEqual(sample.cycleCount, 0)
        XCTAssertNil(sample.temperatureC)
    }

    func testAbsurdAmperageIsDiscarded() {
        // A wrapped/garbage register read must not become a 200 kW reading.
        let properties: [String: Any] = [
            "CurrentCapacity": 50,
            "MaxCapacity": 100,
            "Voltage": 12000,
            "InstantAmperage": 1.8446744073709549e19,
        ]
        let sample = BatteryReader.sample(from: properties, timestampMs: timestamp)
        XCTAssertEqual(sample.amperageMa, 0)
        XCTAssertEqual(sample.wattsDrawn, 0)
    }
}

final class SamplerIntegrationTests: XCTestCase {

    /// The end-to-end write path: a parsed powermetrics batch lands in the store.
    func testParsedSamplesRoundTripThroughTheStore() throws {
        let path = NSTemporaryDirectory() + "batteryscope-sampler-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = try SQLiteStore(path: path, mode: .readWrite)
        let now = Date()
        let timestampMs = Int64((now.timeIntervalSince1970 * 1000).rounded())

        let processes = try PowermetricsParser.parse(
            PowermetricsFixtures.data(PowermetricsFixtures.wellFormed),
            timestampMs: timestampMs
        )
        try store.insert(processSamples: processes)

        let battery = BatteryReader.sample(
            from: [
                "CurrentCapacity": 6000,
                "MaxCapacity": 8000,
                "DesignCapacity": 8000,
                "Voltage": 12000,
                "InstantAmperage": -1500,
                "CycleCount": 12,
            ],
            timestampMs: timestampMs
        )
        try store.insert(batterySample: battery)

        let window = (from: now.addingTimeInterval(-60), to: now.addingTimeInterval(60))
        XCTAssertEqual(try store.processSamples(from: window.from, to: window.to).count, 4)
        let batteries = try store.batterySamples(from: window.from, to: window.to)
        XCTAssertEqual(batteries.count, 1)
        XCTAssertEqual(batteries.first?.wattsDrawn ?? 0, -18, accuracy: 0.0001)
    }

    func testDegradedModeMessagePointsAtTheInstaller() {
        XCTAssertTrue(Sampler.degradedModeMessage.contains("install-daemon.sh"))
        XCTAssertTrue(Sampler.degradedModeMessage.contains("root"))
    }

    // MARK: - Process-sampling skip rule

    private func battery(
        percent: Double,
        isCharging: Bool,
        externalPower: Bool
    ) -> BatterySample {
        BatterySample(
            timestampMs: 0,
            percent: percent,
            isCharging: isCharging,
            externalPower: externalPower,
            wattsDrawn: 0,
            voltageMv: 12000,
            amperageMa: 0,
            cycleCount: 0,
            maxCapacityPct: 100
        )
    }

    func testSkipsProcessSamplingOnACAtFullCharge() {
        XCTAssertTrue(Sampler.shouldSkipProcessSampling(
            battery: battery(percent: 100, isCharging: false, externalPower: true)
        ))
    }

    func testSamplesProcessesWhileDischarging() {
        XCTAssertFalse(Sampler.shouldSkipProcessSampling(
            battery: battery(percent: 100, isCharging: false, externalPower: false)
        ))
    }

    func testSamplesProcessesWhileChargingAndBelowFull() {
        XCTAssertFalse(Sampler.shouldSkipProcessSampling(
            battery: battery(percent: 100, isCharging: true, externalPower: true)
        ))
        XCTAssertFalse(Sampler.shouldSkipProcessSampling(
            battery: battery(percent: 80, isCharging: false, externalPower: true)
        ))
    }

    func testSamplesProcessesWhenBatteryStateIsUnknown() {
        XCTAssertFalse(Sampler.shouldSkipProcessSampling(battery: nil))
    }

    // MARK: - powermetrics availability

    func testPowermetricsIsUnavailableWithoutRoot() {
        XCTAssertFalse(PowermetricsRunner.isAvailable(isRoot: false))
    }

    func testPowermetricsRefusesToRunWithoutRoot() throws {
        try XCTSkipIf(getuid() == 0, "running as root; the unprivileged path cannot be exercised")
        guard case .failure(let failure) = PowermetricsRunner.sampleTasks() else {
            return XCTFail("expected powermetrics to refuse to run unprivileged")
        }
        guard case .notPermitted = failure else {
            return XCTFail("expected .notPermitted, got \(failure)")
        }
    }

    /// A full tick against a real machine: the battery row must land even when
    /// powermetrics is unavailable, which is the whole point of degraded mode.
    func testTickWritesABatterySampleWithoutPrivileges() throws {
        let path = NSTemporaryDirectory() + "batteryscope-tick-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = try SQLiteStore(path: path, mode: .readWrite)
        let sampler = Sampler(
            configuration: Configuration(databasePath: path, runOnce: true),
            store: store
        )
        let now = Date()
        sampler.tick(now: now)

        let samples = try store.batterySamples(
            from: now.addingTimeInterval(-60),
            to: now.addingTimeInterval(60)
        )
        // Machines without an AppleSmartBattery node (desktops, VMs) legitimately
        // write nothing; anywhere else the sample must be present and sane.
        try XCTSkipIf(samples.isEmpty, "no battery on this machine")
        let sample = try XCTUnwrap(samples.first)
        XCTAssertGreaterThanOrEqual(sample.percent, 0)
        XCTAssertLessThanOrEqual(sample.percent, 100)
        XCTAssertGreaterThan(sample.voltageMv, 0)
        XCTAssertTrue(sample.wattsDrawn.isFinite)
    }
}
