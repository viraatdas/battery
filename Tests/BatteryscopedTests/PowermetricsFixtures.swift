import Foundation

/// Hand-authored powermetrics plists.
///
/// They are kept as XML string constants rather than resource files so the test
/// target needs no `resources:` declaration in Package.swift.
enum PowermetricsFixtures {

    static func data(_ xml: String) -> Data {
        Data(xml.utf8)
    }

    /// Four well-formed tasks spanning several categories.
    static let wellFormed = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>is_delta</key><true/>
            <key>elapsed_ns</key><integer>1002345678</integer>
            <key>tasks</key>
            <array>
                <dict>
                    <key>name</key><string>Google Chrome</string>
                    <key>pid</key><integer>451</integer>
                    <key>energy_impact</key><real>132.5</real>
                    <key>cputime_ms_per_s</key><real>84.25</real>
                    <key>path</key><string>/Applications/Google Chrome.app</string>
                </dict>
                <dict>
                    <key>name</key><string>Ghostty</string>
                    <key>pid</key><integer>982</integer>
                    <key>energy_impact</key><real>12.0</real>
                    <key>cputime_ms_per_s</key><real>3.5</real>
                </dict>
                <dict>
                    <key>name</key><string>WindowServer</string>
                    <key>pid</key><integer>144</integer>
                    <key>energy_impact</key><real>41.75</real>
                    <key>cputime_ms_per_s</key><real>22.0</real>
                </dict>
                <dict>
                    <key>name</key><string>notifyd</string>
                    <key>pid</key><integer>210</integer>
                    <key>energy_impact</key><real>0.5</real>
                    <key>cputime_ms_per_s</key><real>0.1</real>
                </dict>
            </array>
        </dict>
        </plist>
        """

    /// Newer-macOS key spellings: `energy_impact_per_s` and
    /// `cputime_sample_ms_per_s` instead of the classic names.
    static let alternateKeys = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>tasks</key>
            <array>
                <dict>
                    <key>name</key><string>Spotify</string>
                    <key>pid</key><integer>777</integer>
                    <key>energy_impact_per_s</key><real>55.5</real>
                    <key>cputime_sample_ms_per_s</key><real>9.75</real>
                </dict>
            </array>
        </dict>
        </plist>
        """

    /// Mixed bag: valid task, task with no name, task that is not a dict,
    /// task whose name is the wrong type, and a task with no counters at all.
    static let malformedEntries = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>tasks</key>
            <array>
                <dict>
                    <key>name</key><string>Slack</string>
                    <key>pid</key><integer>300</integer>
                    <key>energy_impact</key><real>20.0</real>
                    <key>cputime_ms_per_s</key><real>5.0</real>
                </dict>
                <dict>
                    <key>pid</key><integer>301</integer>
                    <key>energy_impact</key><real>9.0</real>
                </dict>
                <string>this is not a task</string>
                <dict>
                    <key>name</key><integer>42</integer>
                    <key>pid</key><integer>302</integer>
                </dict>
                <dict>
                    <key>name</key><string>   </string>
                    <key>pid</key><integer>303</integer>
                </dict>
                <dict>
                    <key>name</key><string>mdworker_shared</string>
                </dict>
            </array>
        </dict>
        </plist>
        """

    /// Well-formed plist that simply has no tasks.
    static let emptyTasks = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict><key>tasks</key><array/></dict>
        </plist>
        """

    /// Well-formed plist with no `tasks` key at all.
    static let noTasksKey = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict><key>elapsed_ns</key><integer>1000000000</integer></dict>
        </plist>
        """

    /// Root is an array, not a dict.
    static let arrayRoot = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <array><string>nope</string></array>
        </plist>
        """

    /// Numbers arriving as strings, and a pid far outside Int32.
    static let stringyNumbers = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>tasks</key>
            <array>
                <dict>
                    <key>name</key><string>node</string>
                    <key>pid</key><string>12345678901234</string>
                    <key>energy_impact</key><string>77.25</string>
                    <key>cputime_ms_per_s</key><string>not-a-number</string>
                </dict>
            </array>
        </dict>
        </plist>
        """

    /// powermetrics grouping by coalition instead of task.
    static let coalitions = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>coalitions</key>
            <array>
                <dict>
                    <key>name</key><string>Safari</string>
                    <key>pid</key><integer>88</integer>
                    <key>energy_impact</key><real>10.0</real>
                    <key>cputime_ms_per_s</key><real>4.0</real>
                </dict>
            </array>
        </dict>
        </plist>
        """
}
