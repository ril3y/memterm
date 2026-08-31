import Foundation

// FR-25: vanished-cwd handling. Never a broken pane, never a silently wrong cd.

public enum CwdFallback {

    /// Stat the saved cwd; fall back to the nearest existing ancestor, else
    /// `home`. A walk that only reaches "/" counts as fully vanished and lands
    /// on home — spawning a shell in "/" helps nobody. Returns (path, fellBack).
    public static func resolve(_ saved: String?,
                               home: String = FileManager.default.homeDirectoryForCurrentUser.path)
        -> (path: String, fellBack: Bool) {
        guard let saved, saved.hasPrefix("/") else { return (home, false) }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: saved, isDirectory: &isDir), isDir.boolValue {
            return (saved, false)
        }
        var url = URL(fileURLWithPath: saved)
        while url.path != "/" {
            url.deleteLastPathComponent()
            if url.path != "/",
               FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return (url.path, true)
            }
        }
        return (home, true)
    }
}
