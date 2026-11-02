import Darwin
import Foundation

struct CPUSample: Sendable {
    let nanoseconds: [pid_t: UInt64]
    let taken: ContinuousClock.Instant

    static func take(tree root: pid_t) -> CPUSample {
        let timebase = machTimebase()
        var totals: [pid_t: UInt64] = [:]
        for pid in ProcessTree.members(of: root) {
            guard let ticks = userAndSystemTicks(of: pid) else { continue }
            totals[pid] = ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
        }
        return CPUSample(nanoseconds: totals, taken: ContinuousClock.now)
    }

    func percent(since start: CPUSample) -> Double {
        var used: UInt64 = 0
        for (pid, now) in nanoseconds {
            let before = start.nanoseconds[pid] ?? 0
            if now > before { used += now - before }
        }
        let wall = start.taken.duration(to: taken).components
        let wallNanoseconds = Double(wall.seconds) * 1e9 + Double(wall.attoseconds) / 1e9
        guard wallNanoseconds > 0 else { return 0 }
        return Double(used) / wallNanoseconds * 100
    }

    private static func machTimebase() -> mach_timebase_info_data_t {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info.denom == 0 ? mach_timebase_info_data_t(numer: 1, denom: 1) : info
    }

    private static func userAndSystemTicks(of pid: pid_t) -> UInt64? {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return status == 0 ? usage.ri_user_time + usage.ri_system_time : nil
    }
}

enum ProcessTree {
    static func members(of root: pid_t) -> [pid_t] {
        var children: [pid_t: [pid_t]] = [:]
        for pid in allPIDs() {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            children[pid_t(info.pbi_ppid), default: []].append(pid)
        }
        var members = [root]
        var index = 0
        while index < members.count {
            members.append(contentsOf: children[members[index]] ?? [])
            index += 1
        }
        return members
    }

    private static func allPIDs() -> [pid_t] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        return Array(pids.prefix(max(count, 0))).filter { $0 > 0 }
    }
}
