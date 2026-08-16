import BatteryCore
import Darwin
import Foundation
import IOKit
import IOKit.storage

/// Reads the machine-wide pressure signals that decide whether a Mac feels
/// responsive: memory, swap, CPU saturation, and heat.
///
/// None of this needs root, unlike `powermetrics` — so the stall diagnosis
/// keeps working in the documented unprivileged mode, where per-process energy
/// does not. That is deliberate: the question "what is wedging my machine" is
/// most often asked by someone who has not installed anything yet.
public enum SystemPressureReader {

    /// Takes one reading. Never throws: any field the kernel declines to
    /// report falls back to a value that reads as "nothing to see", so a
    /// partial reading is still written rather than lost.
    ///
    /// - Parameter intervalSeconds: the cadence the sampler is running at,
    ///   recorded alongside the reading so a later gap in the data can be
    ///   judged against the interval that was actually in force.
    public static func read(timestampMs: Int64, intervalSeconds: Double = 0) -> PressureSample {
        let vm = vmStatistics()
        let pageSize = Int64(vm.pageSize)
        let physical = Int64(ProcessInfo.processInfo.physicalMemory)

        // Activity Monitor's "memory used": app (anonymous, non-purgeable)
        // pages, plus wired pages, plus whatever the compressor is holding.
        // File-backed pages are excluded because the kernel can drop them
        // without cost, so counting them would report a healthy machine with a
        // warm page cache as being out of memory.
        let appPages = Int64(vm.statistics.internal_page_count) - Int64(vm.statistics.purgeable_count)
        let usedPages = max(0, appPages)
            + Int64(vm.statistics.wire_count)
            + Int64(vm.statistics.compressor_page_count)
        let usedBytes = min(usedPages * pageSize, physical)

        let swap = swapUsage()
        let disk = diskTotals()

        return PressureSample(
            timestampMs: timestampMs,
            memoryLevel: memoryPressureLevel(),
            thermalLevel: thermalLevel(),
            totalMemoryBytes: physical,
            availableMemoryBytes: max(0, physical - usedBytes),
            compressedBytes: Int64(vm.statistics.compressor_page_count) * pageSize,
            swapUsedBytes: swap,
            pageIns: Int64(vm.statistics.pageins),
            loadAverage1m: loadAverage1m() ?? 0,
            cpuCount: ProcessInfo.processInfo.activeProcessorCount,
            uptimeSeconds: ProcessInfo.processInfo.systemUptime,
            diskReadBytes: disk.read,
            diskWriteBytes: disk.written,
            intervalSeconds: intervalSeconds
        )
    }

    // MARK: - Disk

    /// Bytes read and written across every block storage device since boot,
    /// from `IOBlockStorageDriver`'s own statistics.
    ///
    /// Zeros when IOKit declines, which reads as "no disk activity recorded"
    /// rather than as a stall.
    static func diskTotals() -> (read: Int64, written: Int64) {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOBlockStorageDriver")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return (0, 0)
        }
        defer { IOObjectRelease(iterator) }

        var read: Int64 = 0
        var written: Int64 = 0
        while case let drive = IOIteratorNext(iterator), drive != 0 {
            defer { IOObjectRelease(drive) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(drive, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  let statistics = dictionary[kIOBlockStorageDriverStatisticsKey] as? [String: Any]
            else { continue }
            read += (statistics[kIOBlockStorageDriverStatisticsBytesReadKey] as? NSNumber)?.int64Value ?? 0
            written += (statistics[kIOBlockStorageDriverStatisticsBytesWrittenKey] as? NSNumber)?.int64Value ?? 0
        }
        return (read, written)
    }

    // MARK: - Memory

    struct VMStatistics {
        var statistics = vm_statistics64_data_t()
        var pageSize: UInt32 = 4096
    }

    /// `host_statistics64(HOST_VM_INFO64)`, or all-zeros when it fails — which
    /// yields a sample reporting no pressure rather than a wrong one.
    static func vmStatistics() -> VMStatistics {
        var result = VMStatistics()

        var pageSize: vm_size_t = 0
        if host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 {
            result.pageSize = UInt32(pageSize)
        }

        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        var statistics = vm_statistics64_data_t()
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        if status == KERN_SUCCESS {
            result.statistics = statistics
        }
        return result
    }

    /// macOS's own memory-pressure verdict, from
    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
    ///
    /// Preferred over any threshold we could invent, because it is the same
    /// signal the OS uses to decide when to start killing processes.
    static func memoryPressureLevel() -> PressureLevel {
        guard let raw = sysctlInt32("kern.memorystatus_vm_pressure_level") else { return .nominal }
        switch raw {
        case 4...: return .critical
        case 2, 3: return .moderate
        default: return .nominal
        }
    }

    /// Bytes currently swapped out, from `vm.swapusage`.
    static func swapUsage() -> Int64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return Int64(bitPattern: usage.xsu_used)
    }

    // MARK: - CPU and heat

    /// `ProcessInfo.thermalState`, mapped onto the shared scale. `serious` and
    /// above mean the system is actively throttling to shed heat.
    static func thermalLevel() -> PressureLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .moderate
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    static func loadAverage1m() -> Double? {
        var averages = [Double](repeating: 0, count: 3)
        guard getloadavg(&averages, 3) > 0 else { return nil }
        return averages[0]
    }

    // MARK: - Helpers

    private static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
