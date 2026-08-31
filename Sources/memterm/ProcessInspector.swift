import Darwin
import Foundation
import CProcShim

// Kernel-truth process capture (FR-13/14): works with zero shell cooperation.
// cwd via libproc PROC_PIDVNODEPATHINFO, argv via sysctl KERN_PROCARGS2,
// foreground job via tcgetpgrp on the pty master.

enum ProcessInspector {

    static func cwd(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 1024) // MAXPATHLEN
        guard memterm_pid_cwd(pid, &buf, buf.count) == 0 else { return nil }
        return String(cString: buf)
    }

    static func childPids(of pid: pid_t) -> [pid_t] {
        guard pid > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: 128)
        let n = memterm_child_pids(pid, &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return [] }
        return Array(buf.prefix(Int(n)))
    }

    /// Foreground process group of the pane's tty, read from the master side.
    static func foregroundPgid(masterFd: Int32) -> pid_t? {
        guard masterFd >= 0 else { return nil }
        let pgid = tcgetpgrp(masterFd)
        return pgid > 0 ? pgid : nil
    }

    /// Full post-expansion argv (KERN_PROCARGS2). Layout: argc, exec_path,
    /// NUL padding, then argc NUL-terminated argv strings.
    static func argv(of pid: pid_t) -> [String]? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }

        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        guard argc > 0 else { return nil }
        var i = MemoryLayout<Int32>.size
        while i < size && buf[i] != 0 { i += 1 } // skip exec_path
        while i < size && buf[i] == 0 { i += 1 } // skip padding

        var args: [String] = []
        var start = i
        while i < size && args.count < argc {
            if buf[i] == 0 {
                args.append(String(decoding: buf[start..<i], as: UTF8.self))
                start = i + 1
            }
            i += 1
        }
        return args.isEmpty ? nil : args
    }

    /// FR-18: discriminates app-restart restore from reboot restore.
    static func bootSessionUUID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}
