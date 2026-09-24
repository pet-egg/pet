import Darwin
import Foundation

/// Samples the aggregate CPU usage of the Claude desktop app's process tree as
/// a proxy for "a response is streaming right now" (→ the 달리기/running pet).
///
/// Why CPU and not the Accessibility API: Claude is an Electron app and does
/// **not** expose its web content to AX (probing shows `AXWindows == 0` and no
/// text/buttons for the chat surface even with `AXManualAccessibility` forced),
/// so there's no "정지(stop) button visible" signal to read. Renderer CPU is the
/// most reliable no-extra-permission stand-in: idle sits near ~0%, while token
/// streaming keeps the `Claude Helper (Renderer)` process busy repainting.
///
/// CPU time is read via `proc_pid_rusage` (cumulative user+system nanoseconds)
/// and differenced across polls — an *instantaneous* rate, unlike `ps`'s
/// lifetime-decaying average. The Claude PID set (main app + all helpers) is
/// rediscovered lazily every couple seconds, then sampled every poll.
final class ClaudeProcessActivity {
    private let pathMatch: String
    private let pidRefreshInterval: TimeInterval

    private var claudePIDs: [pid_t] = []
    private var pidRefreshDeadline: Date = .distantPast
    private var lastTotalTicks: UInt64 = 0
    private var lastSampleTime: Date?

    // proc_pid_rusage's ri_user_time/ri_system_time come back in mach absolute
    // time units, not nanoseconds (empirically ~41.67× off on Apple Silicon,
    // exactly the 125/3 timebase). Convert ticks → ns via the machine timebase;
    // on Intel this is 1/1 and a no-op.
    private let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    init(pathMatch: String = "/Claude.app/", pidRefreshInterval: TimeInterval = 2.0) {
        self.pathMatch = pathMatch
        self.pidRefreshInterval = pidRefreshInterval
    }

    /// Aggregate CPU fraction consumed since the previous call, where 1.0 == one
    /// fully-saturated core (can exceed 1.0 across helpers). Returns 0 on the
    /// first call (no previous sample to diff against) and whenever Claude isn't
    /// running.
    func sampleCPUFraction(now: Date) -> Double {
        refreshPIDsIfNeeded(now: now)

        var total: UInt64 = 0
        for pid in claudePIDs { total &+= Self.cpuTicks(pid) }

        defer {
            lastTotalTicks = total
            lastSampleTime = now
        }

        // A shrinking total means a helper we were counting exited (its ticks
        // drop out of the sum) — treat as no measurable work this interval
        // rather than a bogus negative rate.
        guard let last = lastSampleTime, total >= lastTotalTicks else { return 0 }
        let elapsed = now.timeIntervalSince(last)
        guard elapsed > 0 else { return 0 }
        let deltaNanos = Double(total - lastTotalTicks)
            * Double(timebase.numer) / Double(timebase.denom)
        let deltaSeconds = deltaNanos / 1_000_000_000.0
        return deltaSeconds / elapsed
    }

    /// Drops cached CPU/PID state so the next `sampleCPUFraction` starts clean
    /// (called when the watcher (re)starts, so a long gap isn't counted as one
    /// giant busy interval).
    func reset() {
        claudePIDs = []
        pidRefreshDeadline = .distantPast
        lastTotalTicks = 0
        lastSampleTime = nil
    }

    private func refreshPIDsIfNeeded(now: Date) {
        guard now >= pidRefreshDeadline else { return }
        pidRefreshDeadline = now.addingTimeInterval(pidRefreshInterval)
        claudePIDs = Self.allPIDs().filter { Self.path(of: $0).contains(pathMatch) }
    }

    // MARK: - libproc helpers

    private static func cpuTicks(_ pid: pid_t) -> UInt64 {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPtr in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, reboundPtr)
            }
        }
        guard rc == 0 else { return 0 }
        return info.ri_user_time &+ info.ri_system_time
    }

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        // Over-allocate: the set can grow between the sizing call and the fill.
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let bytes = Int32(pids.count) * Int32(MemoryLayout<pid_t>.size)
        let filled = pids.withUnsafeMutableBufferPointer { proc_listallpids($0.baseAddress, bytes) }
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled))).filter { $0 > 0 }
    }

    private static func path(of pid: pid_t) -> String {
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) isn't imported into Swift.
        var buf = [CChar](repeating: 0, count: 4 * 1024)
        let len = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard len > 0 else { return "" }
        return String(cString: buf)
    }
}
