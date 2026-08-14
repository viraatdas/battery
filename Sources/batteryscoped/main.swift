import BatteryCore
import Foundation
import os

// batteryscoped — BatteryScope sampling daemon.
//
// Reads the battery from IOKit (no privileges needed) and per-process energy
// from powermetrics (root only), writing both into the SQLite store the app
// reads. Running unprivileged is a supported degraded mode, not an error.

let mainLog = Logger(subsystem: "com.batteryscope.daemon", category: "main")
let defaultDatabasePath = DBLocation.writablePath()

let configuration: Configuration
do {
    configuration = try Configuration.parse(
        arguments: Array(CommandLine.arguments.dropFirst()),
        defaultDatabasePath: defaultDatabasePath
    )
} catch {
    FileHandle.standardError.write(Data("batteryscoped: \(error)\n".utf8))
    FileHandle.standardError.write(Data((Configuration.usage(defaultDatabasePath: defaultDatabasePath) + "\n").utf8))
    exit(EXIT_FAILURE)
}

if configuration.showHelp {
    print(Configuration.usage(defaultDatabasePath: defaultDatabasePath))
    exit(EXIT_SUCCESS)
}

let store: SQLiteStore
do {
    store = try SQLiteStore(path: configuration.databasePath, mode: .readWrite)
} catch {
    mainLog.error("cannot open store: \(String(describing: error), privacy: .public)")
    FileHandle.standardError.write(
        Data("batteryscoped: cannot open \(configuration.databasePath): \(error)\n".utf8)
    )
    exit(EXIT_FAILURE)
}

let sampler = Sampler(configuration: configuration, store: store)

if configuration.runOnce {
    sampler.tick()
    exit(EXIT_SUCCESS)
}

sampler.run()
