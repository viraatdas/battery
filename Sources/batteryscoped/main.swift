import BatteryCore
import Foundation

// batteryscoped: sampling daemon stub. Real sampling (powermetrics, IOKit)
// is implemented by a later node; this stub only prints usage.

let usage = """
batteryscoped — BatteryScope sampling daemon (stub)

Usage:
    batteryscoped [--db <path>]

Options:
    --db <path>    Database path (default: \(BatteryScopePaths.defaultDBPath))
    -h, --help     Show this help.

Sampling is not implemented yet.
"""

print(usage)
exit(EXIT_SUCCESS)
