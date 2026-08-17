import Foundation

/// Terminal tabs, identified from the process tree.
///
/// "Ghostty is using 40% of your battery" is useless when eight tabs are open.
/// The useful answer names the tab — and a tab is a real, findable thing in the
/// process tree, not something that needs the accessibility API or a screen
/// recording permission to see.
///
/// Every macOS terminal spawns one login shell per tab:
///
///     ghostty → login → zsh → claude
///     ghostty → login → zsh → npm → node
///
/// So each shell that is a grandchild of the terminal *is* a tab, its working
/// directory names it, and everything beneath it is that tab's cost. That is
/// also where the terminal gets the title it shows, so the label matches what
/// is on screen without ever reading the screen.
public enum TerminalTabs {

    /// Terminal emulators whose children are tabs.
    public static let terminalNames: Set<String> = [
        "ghostty", "terminal", "iterm2", "iterm", "alacritty", "kitty",
        "wezterm-gui", "wezterm", "warp", "hyper", "tabby", "rio",
    ]

    /// Processes that sit between the terminal and the shell and carry no
    /// meaning of their own. `login` is the standard one on macOS.
    static let passthroughNames: Set<String> = ["login", "bash", "sh", "zsh", "fish", "tmux", "screen"]

    public static func isTerminal(name: String) -> Bool {
        terminalNames.contains(normalized(name))
    }

    static func isPassthrough(name: String) -> Bool {
        passthroughNames.contains(normalized(name))
    }

    static func normalized(_ name: String) -> String {
        var value = name
        if let slash = value.lastIndex(of: "/") {
            value = String(value[value.index(after: slash)...])
        }
        // Login shells are exec'd with a leading dash: `-zsh`.
        if value.hasPrefix("-") { value.removeFirst() }
        return value.lowercased()
    }

    /// Groups one tick's processes into tabs.
    ///
    /// Returns one entry per tab that had any measurable cost, plus the pids
    /// belonging to it so a caller can attribute whatever it likes.
    public static func tabs(inTick samples: [ProcessSample]) -> [TerminalTab] {
        var byPid: [Int32: ProcessSample] = [:]
        for sample in samples where sample.pid >= 0 {
            byPid[sample.pid] = sample
        }
        guard byPid.values.contains(where: { isTerminal(name: $0.name) }) else { return [] }

        // A tab root is the outermost process under a terminal that is not
        // itself pure plumbing. Walking down from the terminal rather than up
        // from the leaves keeps `login`/`zsh` out of the label.
        var rootOf: [Int32: Int32] = [:]
        for sample in byPid.values {
            guard let root = tabRoot(for: sample, in: byPid) else { continue }
            rootOf[sample.pid] = root
        }

        var members: [Int32: [ProcessSample]] = [:]
        for (pid, root) in rootOf {
            guard let sample = byPid[pid] else { continue }
            members[root, default: []].append(sample)
        }

        return members.compactMap { rootPid, processes -> TerminalTab? in
            guard let root = byPid[rootPid] else { return nil }
            let residents = processes.compactMap(\.residentBytes)
            // The command is the most interesting descendant, not the shell.
            let command = processes
                .filter { !isPassthrough(name: $0.name) && !isTerminal(name: $0.name) }
                .max { $0.cpuCores < $1.cpuCores }
            return TerminalTab(
                rootPid: rootPid,
                terminalName: terminalName(above: root, in: byPid) ?? "terminal",
                directory: directory(of: rootPid, processes: processes, in: byPid),
                command: command.map { $0.name },
                pids: Set(processes.map(\.pid)),
                energyImpact: processes.reduce(0) { $0 + $1.energyImpact },
                cpuCores: processes.reduce(0) { $0 + $1.cpuCores },
                residentBytes: residents.isEmpty ? nil : residents.reduce(0, +)
            )
        }
        .sorted { $0.energyImpact + $0.cpuCores > $1.energyImpact + $1.cpuCores }
    }

    /// The tab a process belongs to: the pid of the terminal's *direct child*,
    /// which is one per tab and the same for every process inside it.
    ///
    /// It has to be the direct child rather than, say, the shallowest
    /// interesting process, because the root doubles as the tab's identity —
    /// and picking per-process would give the shell one identity and the
    /// command another, splitting a single tab into several. The label comes
    /// from the members afterwards, which is where `login` and `zsh` get
    /// filtered out.
    static func tabRoot(for sample: ProcessSample, in byPid: [Int32: ProcessSample]) -> Int32? {
        var current = sample
        var seen: Set<Int32> = [sample.pid]
        var depth = 0
        while depth < 24,
              let ppid = current.ppid,
              ppid > 0,
              !seen.contains(ppid),
              let parent = byPid[ppid] {
            if isTerminal(name: parent.name) { return current.pid }
            seen.insert(ppid)
            current = parent
            depth += 1
        }
        return nil
    }

    private static func terminalName(above sample: ProcessSample, in byPid: [Int32: ProcessSample]) -> String? {
        var current = sample
        var depth = 0
        while depth < 24, let ppid = current.ppid, ppid > 0, let parent = byPid[ppid] {
            if isTerminal(name: parent.name) { return parent.name }
            current = parent
            depth += 1
        }
        return nil
    }

    /// The tab's directory: whichever member reported one, preferring the shell
    /// closest to the terminal, since that is the one the title follows.
    private static func directory(
        of rootPid: Int32,
        processes: [ProcessSample],
        in byPid: [Int32: ProcessSample]
    ) -> String? {
        if let direct = byPid[rootPid]?.workingDirectory { return direct }
        return processes.compactMap(\.workingDirectory).first
    }
}

/// One terminal tab and what it cost.
public struct TerminalTab: Sendable, Hashable, Identifiable {
    public var id: Int32 { rootPid }

    public var rootPid: Int32
    public var terminalName: String
    /// Working directory of the tab's shell, when it could be read.
    public var directory: String?
    /// The busiest thing running in the tab.
    public var command: String?
    public var pids: Set<Int32>
    public var energyImpact: Double
    public var cpuCores: Double
    public var residentBytes: Int64?

    public init(
        rootPid: Int32,
        terminalName: String,
        directory: String?,
        command: String?,
        pids: Set<Int32>,
        energyImpact: Double,
        cpuCores: Double,
        residentBytes: Int64?
    ) {
        self.rootPid = rootPid
        self.terminalName = terminalName
        self.directory = directory
        self.command = command
        self.pids = pids
        self.energyImpact = energyImpact
        self.cpuCores = cpuCores
        self.residentBytes = residentBytes
    }

    /// What to call this tab: the folder it is sitting in, which is what the
    /// terminal itself shows in the tab. Falls back to the command, then to the
    /// terminal's own name.
    public var label: String {
        if let folder = directoryName { return folder }
        if let command { return command }
        return terminalName
    }

    /// Last path component of the working directory, with `~` collapsed.
    public var directoryName: String? {
        guard let directory, !directory.isEmpty else { return nil }
        let trimmed = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        guard let last = trimmed.split(separator: "/").last else { return nil }
        return String(last)
    }

    /// `battery — claude`: the tab, and what is running in it.
    public var detail: String? {
        guard let command, command != directoryName else { return nil }
        return command
    }
}
