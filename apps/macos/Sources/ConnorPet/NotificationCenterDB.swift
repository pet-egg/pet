import Darwin
import Foundation
import SQLite3

/// Read-only accessor for macOS's per-user Notification Center database — the
/// SQLite file every app's banners/alerts land in. We use it as the *only*
/// reliable "the Claude desktop app finished a turn" signal: the app posts a
/// completion notification ("Claude가 작업을 완료했습니다"), which shows up here as a
/// new `record` row for `com.anthropic.claudefordesktop`.
///
/// The DB lives under `$DARWIN_USER_DIR/com.apple.notificationcenter/db2/db`
/// (a per-user path resolved via `confstr(_CS_DARWIN_USER_DIR)`), and reading
/// it requires the host app to have **Full Disk Access** on recent macOS — if
/// the grant is missing the open simply fails and we degrade to "no done
/// signal" rather than crashing (see `ClaudeDesktopStatusWatcher`).
///
/// We never write, and open with `SQLITE_OPEN_READONLY` + a short busy timeout
/// so a concurrent write from `notificationd` just yields `nil` on that poll.
final class NotificationCenterDB {
    private let dbPath: String

    // SQLite wants a copy of bound text; -1 == SQLITE_TRANSIENT.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?() {
        guard let dir = Self.darwinUserDir() else { return nil }
        self.dbPath = (dir as NSString)
            .appendingPathComponent("com.apple.notificationcenter/db2/db")
    }

    /// Whether the underlying DB file exists and is readable at all (used to
    /// surface a one-time "grant Full Disk Access" hint, not per-poll).
    var isReadable: Bool { FileManager.default.isReadableFile(atPath: dbPath) }

    /// Most-recent notification timestamp (Cocoa epoch seconds — add
    /// 978307200 for Unix) posted by `bundleID`, or `nil` if there are none /
    /// the DB is unavailable. Callers treat a *strictly increasing* value
    /// across polls as "a new notification just fired".
    func latestNotificationDate(bundleID: String) -> Double? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 50)

        // delivered_date is the banner's on-screen time; fall back to the
        // request timestamps for records not yet marked delivered.
        let sql = """
        SELECT MAX(COALESCE(delivered_date, request_last_date, request_date))
        FROM record
        WHERE app_id = (SELECT app_id FROM app WHERE identifier = ?1)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, bundleID, -1, Self.transient)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, 0)
    }

    /// `$DARWIN_USER_DIR` — the per-user `/var/folders/.../0/` root the
    /// notification DB (and other per-user caches) live under.
    private static func darwinUserDir() -> String? {
        let len = confstr(_CS_DARWIN_USER_DIR, nil, 0)
        guard len > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: len)
        guard confstr(_CS_DARWIN_USER_DIR, &buf, len) > 0 else { return nil }
        return String(cString: buf)
    }
}
