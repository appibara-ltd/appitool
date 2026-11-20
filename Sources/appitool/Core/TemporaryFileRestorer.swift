import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Captures in-memory snapshots of mutated project files (e.g. `project.pbxproj` and temporary `Info.plist` edits)
/// and restores them cleanly on completion, error, deallocation, or termination signal (`SIGINT`/`SIGTERM`).
final class TemporaryFileRestorer: @unchecked Sendable {
    private let lock = NSLock()
    private var backups: [URL: Data] = [:]
    private var signalSources: [any DispatchSourceSignal] = []
    private let signalQueue = DispatchQueue(label: "com.appitool.temporary-file-restorer", qos: .userInitiated)
    private let enableSignalHandlers: Bool

    private static let handledSignals: [Int32] = [SIGINT, SIGTERM]

    init(enableSignalHandlers: Bool = true) {
        self.enableSignalHandlers = enableSignalHandlers
    }

    deinit {
        restoreAll()
    }

    var hasPendingBackups: Bool {
        lock.withLock { !backups.isEmpty }
    }

    /// Snapshots the current on-disk contents of `url` unless a snapshot for it is already recorded.
    func backup(_ url: URL) throws {
        let normalized = url.standardizedFileURL
        let alreadyBackedUp = lock.withLock { backups[normalized] != nil }
        guard !alreadyBackedUp else { return }

        let data = try Data(contentsOf: normalized)
        registerBackup(data, for: normalized)
    }

    /// Registers a pre-read original byte snapshot for `url` (preserving the first recorded snapshot if called repeatedly).
    func registerBackup(_ data: Data, for url: URL) {
        let normalized = url.standardizedFileURL
        lock.withLock {
            if backups[normalized] == nil {
                backups[normalized] = data
            }
            if enableSignalHandlers && signalSources.isEmpty {
                armSignalHandlersLocked()
            }
        }
    }

    /// Restores all recorded backups atomically, disarms signal handlers, and returns the restored file URLs.
    @discardableResult
    func restoreAll() -> [URL] {
        let (pending, sources): ([URL: Data], [any DispatchSourceSignal]) = lock.withLock {
            let currentBackups = backups
            let currentSources = signalSources
            backups.removeAll()
            signalSources.removeAll()
            return (currentBackups, currentSources)
        }

        disarmSignalHandlers(sources)

        var restored: [URL] = []
        for (url, data) in pending {
            do {
                try data.write(to: url, options: .atomic)
                restored.append(url)
            } catch {
                // Best-effort restore inside defer/signal paths
            }
        }
        return restored
    }

    private func armSignalHandlersLocked() {
        for sig in Self.handledSignals {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
            source.setEventHandler { [weak self] in
                self?.restoreAll()
                signal(sig, SIG_DFL)
                raise(sig)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func disarmSignalHandlers(_ sources: [any DispatchSourceSignal]) {
        guard !sources.isEmpty else { return }
        for source in sources {
            source.cancel()
        }
        for sig in Self.handledSignals {
            signal(sig, SIG_DFL)
        }
    }
}
