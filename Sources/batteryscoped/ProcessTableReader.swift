import BatteryCore
import Darwin
import Foundation

/// Reads parent-process ids and resident memory straight from the kernel.
///
/// `powermetrics` reports energy and CPU but neither ancestry nor memory, and
/// both are needed to say anything about why a machine is wedged: ancestry is
/// what groups eight `claude` processes into one session, and resident memory
/// is what actually exhausts the machine. So each tick pairs the powermetrics
/// sample with a snapshot of the process table taken at the same moment.
///
/// Every failure degrades to "no data for this pid" rather than throwing. The
/// process table is a moving target — processes exit between the two reads as a
/// matter of course — so a missing entry is the normal case, not an error.
public enum ProcessTableReader {

    public struct Entry: Sendable, Hashable {
        public var pid: Int32
        public var ppid: Int32
        /// Executable name as the kernel records it (`p_comm`), truncated to 16
        /// characters by the kernel itself. Long enough for every name the
        /// agent roster matches on, and free — unlike `proc_pidpath`, which
        /// would be a syscall per process on a table of several hundred.
        public var name: String
        /// Physical memory held, or `nil` when this process could not be
        /// inspected. Reading another user's task info requires privilege; the
        /// installed daemon runs as root and sees everything, an unprivileged
        /// run sees only its own processes.
        public var residentBytes: Int64?
        /// Cumulative CPU time since the process started, in nanoseconds.
        /// Meaningless alone — the sampler differences it against the previous
        /// tick to get a rate. `nil` when task info could not be read.
        public var cpuNanoseconds: UInt64?
        /// Cumulative bytes this process has read from and written to disk.
        /// Differenced the same way. `nil` when resource usage is unreadable.
        public var diskReadBytes: UInt64?
        public var diskWriteBytes: UInt64?
    }

    /// Snapshot of every process the caller can see, keyed by pid.
    ///
    /// Returns an empty dictionary if the kernel refuses the query outright,
    /// which leaves the tick's process samples exactly as powermetrics
    /// reported them — no ancestry, no memory, still perfectly usable for
    /// battery attribution.
    public static func snapshot() -> [Int32: Entry] {
        guard let processes = kernelProcessList() else { return [:] }

        // One buffer, reused for every process's argument read, sized once from
        // the kernel's own maximum.
        var argumentBuffer = [UInt8](repeating: 0, count: argumentMaximum())

        var entries: [Int32: Entry] = [:]
        entries.reserveCapacity(processes.count)
        for process in processes {
            let pid = process.kp_proc.p_pid
            guard pid > 0 else { continue }
            let task = taskInfo(ofPid: pid)
            let usage = resourceUsage(ofPid: pid)
            entries[pid] = Entry(
                pid: pid,
                ppid: process.kp_eproc.e_ppid,
                name: name(of: process, buffer: &argumentBuffer),
                residentBytes: task.map { Int64(bitPattern: $0.pti_resident_size) },
                cpuNanoseconds: task.map { $0.pti_total_user + $0.pti_total_system },
                diskReadBytes: usage?.ri_diskio_bytesread,
                diskWriteBytes: usage?.ri_diskio_byteswritten
            )
        }
        return entries
    }

    /// The name to record for a process: its `argv[0]`, falling back to the
    /// kernel's `p_comm`.
    ///
    /// The fallback is not the same answer. `p_comm` is the *executable's*
    /// name, truncated to 16 characters — so a tool distributed as a Node
    /// script shows up as `node`, and every coding agent that ships that way
    /// becomes invisible to the roster. `argv[0]` is what the tool calls
    /// itself, which is also what `ps` prints and what a person would recognise.
    /// Verified against a live machine: `p_comm` reads `node` for the very
    /// processes `ps` calls `claude`.
    static func name(of process: kinfo_proc, buffer: inout [UInt8]) -> String {
        if let argv0 = argumentZero(ofPid: process.kp_proc.p_pid, buffer: &buffer) {
            return argv0
        }
        return commandName(of: process)
    }

    /// `p_comm` decoded from its fixed-size C character tuple.
    static func commandName(of process: kinfo_proc) -> String {
        withUnsafeBytes(of: process.kp_proc.p_comm) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// The largest argument block the kernel will hand back, from `kern.argmax`.
    static func argumentMaximum() -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.argmax", &value, &size, nil, 0) == 0, value > 0 else {
            return 4096
        }
        return Int(value)
    }

    /// Basename of `argv[0]` for one pid, via `KERN_PROCARGS2`.
    ///
    /// Returns `nil` when the kernel refuses — reading another user's arguments
    /// requires privilege, so an unprivileged sampler gets this for its own
    /// user's processes and falls back to `p_comm` for the rest. That is the
    /// right trade: the agents worth grouping belong to the user running them.
    ///
    /// The block's layout is `argc`, then the executable path, then padding
    /// nulls, then the argument vector.
    static func argumentZero(ofPid pid: Int32, buffer: inout [UInt8]) -> String? {
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        let status = buffer.withUnsafeMutableBytes { raw in
            sysctl(&name, 3, raw.baseAddress, &size, nil, 0)
        }
        let headerSize = MemoryLayout<Int32>.size
        guard status == 0, size > headerSize else { return nil }

        var index = headerSize
        while index < size, buffer[index] != 0 { index += 1 }   // executable path
        while index < size, buffer[index] == 0 { index += 1 }   // padding
        let start = index
        while index < size, buffer[index] != 0 { index += 1 }   // argv[0]
        guard start < index else { return nil }

        let argument = String(decoding: buffer[start..<index], as: UTF8.self)
        guard !argument.isEmpty else { return nil }
        if let slash = argument.lastIndex(of: "/") {
            let base = String(argument[argument.index(after: slash)...])
            return base.isEmpty ? nil : base
        }
        return argument
    }

    /// `sysctl(KERN_PROC_ALL)` into a right-sized buffer.
    ///
    /// The size is queried first and then padded: the table can grow between
    /// the sizing call and the fetch, and an undersized buffer fails the whole
    /// read with ENOMEM. One retry covers a table that grew past even the pad.
    static func kernelProcessList(retries: Int = 1) -> [kinfo_proc]? {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var length = 0
        guard sysctl(&name, UInt32(name.count), nil, &length, nil, 0) == 0, length > 0 else {
            return nil
        }

        // Pad by 64 entries' worth so ordinary churn between the two calls does
        // not cost a retry.
        let stride = MemoryLayout<kinfo_proc>.stride
        var capacity = length + 64 * stride
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: capacity / stride + 1)

        let result = buffer.withUnsafeMutableBytes { raw -> Int32 in
            capacity = raw.count
            return sysctl(&name, UInt32(name.count), raw.baseAddress, &capacity, nil, 0)
        }
        guard result == 0 else {
            guard retries > 0, errno == ENOMEM else { return nil }
            return kernelProcessList(retries: retries - 1)
        }

        let count = capacity / stride
        guard count > 0 else { return [] }
        return Array(buffer.prefix(count))
    }

    /// `PROC_PIDTASKINFO` selector for `proc_pidinfo`, from `<libproc.h>`.
    private static let procPidTaskInfo: Int32 = 4

    /// Task info for one pid, or `nil` when it cannot be read (the process
    /// exited, or belongs to another user and we are unprivileged).
    static func taskInfo(ofPid pid: Int32) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let written = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, procPidTaskInfo, 0, pointer, size)
        }
        guard written == size else { return nil }
        return info
    }

    static func residentBytes(ofPid pid: Int32) -> Int64? {
        taskInfo(ofPid: pid).map { Int64(bitPattern: $0.pti_resident_size) }
    }

    /// Cumulative resource usage for one pid, which is where per-process disk
    /// I/O lives. `nil` when it cannot be read.
    ///
    /// Disk stalls are one of the most common reasons a Mac feels frozen and
    /// are invisible in every other signal here — a process can pin the machine
    /// while using little CPU and no unusual memory.
    /// `proc_pid_rusage` fills a struct the *caller* owns; its Swift signature
    /// says `UnsafeMutablePointer<rusage_info_t?>` only because the C parameter
    /// is a `void **`. Passing the address of a lone pointer variable, as that
    /// signature invites, hands the kernel eight bytes to write several hundred
    /// into — which trapped on the first call. The struct is allocated here and
    /// its address rebound instead.
    static func resourceUsage(ofPid pid: Int32) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard status == 0 else { return nil }
        return info
    }

    // MARK: - Agent samples

    /// How many processes to keep per resource, on top of the agent trees.
    ///
    /// Small on purpose. The point is to name a culprit, and a stall is never
    /// caused by the 9th-heaviest process; keeping everything is the job of
    /// `process_samples`, which is roughly fifty times larger per tick.
    public static let topProcessesPerResource = 6

    /// Builds process samples for everything worth remembering about this tick:
    /// every coding-agent session, plus the machine's heaviest processes by
    /// memory, CPU, and disk regardless of what they are.
    ///
    /// This is the path that works without root. `powermetrics` is what needs
    /// privilege, and it supplies energy impact — which the stall analysis does
    /// not use. Ancestry, memory, CPU time, and disk I/O all come from the
    /// process table, which any user can read.
    ///
    /// Including the top-N by resource is what lets a stall be blamed on
    /// Spotlight, Time Machine, or a runaway browser rather than reported with
    /// no culprit at all. Agents get whole *trees* because a session is the
    /// unit worth naming; everything else gets individual processes, because
    /// there is no session to speak of.
    ///
    /// - Parameter previous: the prior tick's snapshot, used to turn cumulative
    ///   CPU and disk counters into rates. Pass `nil` on the first tick; those
    ///   samples then report no rate rather than a fabricated one.
    public static func trackedSamples(
        timestampMs: Int64,
        snapshot: [Int32: Entry],
        previous: PreviousSnapshot?
    ) -> [ProcessSample] {
        guard !snapshot.isEmpty else { return [] }

        let candidates = snapshot.values.map { entry in
            let rates = rates(for: entry, previous: previous, nowMs: timestampMs)
            return ProcessSample(
                timestampMs: timestampMs,
                pid: entry.pid,
                name: entry.name,
                energyImpact: 0,
                cpuMsPerS: rates.cpuMsPerS,
                category: Categorizer.categorize(name: entry.name, bundlePathHint: nil),
                ppid: entry.ppid,
                residentBytes: entry.residentBytes,
                diskReadBytesPerS: rates.diskReadBytesPerS,
                diskWriteBytesPerS: rates.diskWriteBytesPerS
            )
        }

        // Agent trees, whole. Reuses the grouping the analytics layer uses, so
        // the daemon and the app can never disagree about what a session is.
        var keep = Set(
            AgentSessions.footprints(inTick: candidates).flatMap { footprint -> [Int32] in
                memberPids(ofRoot: footprint.rootPid, in: snapshot)
            }
        )

        // The heaviest processes on each axis, whether or not anyone asked
        // about them. A process at rest on every axis is not worth a row.
        keep.formUnion(topPids(candidates) { Double($0.residentBytes ?? 0) })
        keep.formUnion(topPids(candidates) { $0.cpuMsPerS })
        keep.formUnion(topPids(candidates) { $0.diskBytesPerS ?? 0 })

        return candidates.filter { keep.contains($0.pid) }
    }

    /// The `topProcessesPerResource` pids with the largest nonzero `measure`.
    private static func topPids(
        _ candidates: [ProcessSample],
        by measure: (ProcessSample) -> Double
    ) -> [Int32] {
        candidates
            .filter { measure($0) > 0 }
            .sorted { lhs, rhs in
                let left = measure(lhs)
                let right = measure(rhs)
                if left != right { return left > right }
                return lhs.pid < rhs.pid
            }
            .prefix(topProcessesPerResource)
            .map(\.pid)
    }

    /// A snapshot plus the instant it was taken, which is what a rate needs.
    public struct PreviousSnapshot: Sendable {
        public var timestampMs: Int64
        public var entries: [Int32: Entry]

        public init(timestampMs: Int64, entries: [Int32: Entry]) {
            self.timestampMs = timestampMs
            self.entries = entries
        }
    }

    /// Per-second rates derived from the change in this process's cumulative
    /// counters.
    ///
    /// Everything is zero (CPU) or `nil` (disk) when there is no comparable
    /// prior reading — including when the pid was reused, which shows up as a
    /// counter going backwards. A counter that has gone backwards belongs to a
    /// different process wearing the same pid, and differencing it would invent
    /// an enormous rate at exactly the wrong moment.
    static func rates(
        for entry: Entry,
        previous: PreviousSnapshot?,
        nowMs: Int64
    ) -> (cpuMsPerS: Double, diskReadBytesPerS: Double?, diskWriteBytesPerS: Double?) {
        guard let previous, let before = previous.entries[entry.pid] else {
            return (0, nil, nil)
        }
        let elapsedSeconds = Double(nowMs - previous.timestampMs) / 1000
        guard elapsedSeconds > 0 else { return (0, nil, nil) }

        func rate(_ current: UInt64?, _ prior: UInt64?) -> Double? {
            guard let current, let prior, current >= prior else { return nil }
            return Double(current - prior) / elapsedSeconds
        }

        let cpuNsPerS = rate(entry.cpuNanoseconds, before.cpuNanoseconds) ?? 0
        return (
            cpuMsPerS: cpuNsPerS / 1_000_000,
            diskReadBytesPerS: rate(entry.diskReadBytes, before.diskReadBytes),
            diskWriteBytesPerS: rate(entry.diskWriteBytes, before.diskWriteBytes)
        )
    }

    /// CPU milliseconds per second of wall time. Kept as a named entry point
    /// because it is the one rate with a meaningful zero.
    static func cpuMsPerS(
        for entry: Entry,
        previous: PreviousSnapshot?,
        nowMs: Int64
    ) -> Double {
        rates(for: entry, previous: previous, nowMs: nowMs).cpuMsPerS
    }

    /// Every pid whose ancestor chain reaches `root`, plus `root` itself.
    static func memberPids(ofRoot root: Int32, in snapshot: [Int32: Entry]) -> [Int32] {
        snapshot.values.compactMap { entry -> Int32? in
            var current = entry
            var depth = 0
            var seen: Set<Int32> = [entry.pid]
            while depth < maxAncestorDepth {
                if current.pid == root { return entry.pid }
                guard current.ppid > 0,
                      !seen.contains(current.ppid),
                      let parent = snapshot[current.ppid] else { return nil }
                seen.insert(current.ppid)
                current = parent
                depth += 1
            }
            return nil
        }
    }

    /// Matches `AgentSessions.maxAncestorDepth`; kept local so this file does
    /// not depend on that constant staying public.
    private static let maxAncestorDepth = 24

    /// Copies ancestry and memory from a process-table snapshot onto the
    /// samples powermetrics produced, matching on pid.
    ///
    /// Samples whose pid is absent from the snapshot pass through untouched,
    /// keeping their `nil` ancestry — which is the honest record of "not
    /// measured", and is what the grouping and stall analysis expect.
    public static func enrich(
        _ samples: [ProcessSample],
        with snapshot: [Int32: Entry]
    ) -> [ProcessSample] {
        guard !snapshot.isEmpty else { return samples }
        return samples.map { sample in
            guard let entry = snapshot[sample.pid] else { return sample }
            var enriched = sample
            enriched.ppid = entry.ppid
            enriched.residentBytes = entry.residentBytes
            return enriched
        }
    }
}
