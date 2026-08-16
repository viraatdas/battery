import Foundation

/// The one command that turns on per-process attribution.
///
/// Shared by `OnboardingView` (no database yet) and the ready-state notice
/// shown when the database exists but has never recorded a process sample —
/// both are the same instruction, just reached from different states.
enum SamplerInstall {
    static let command = "sudo ./Scripts/install-daemon.sh"
}
