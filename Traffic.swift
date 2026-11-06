import Foundation
import SQLite3

struct Snapshot: Decodable {
    var uploadTotal: Int64
    var downloadTotal: Int64
    var connections: [Connection]?
    var source: String?

    static func read() throws -> Self {
        let paths = [
            "/var/run/clash-verge-service/users/\(getuid())/verge-mihomo.sock",
            FileManager.default.temporaryDirectory.appendingPathComponent("verge-mihomo.sock").path,
            "/tmp/verge/verge-mihomo.sock"
        ]
        for path in paths where FileManager.default.fileExists(atPath: path) {
            var bytes: UnsafeMutablePointer<UInt8>?
            var length = 0
            if read_connections(path, &bytes, &length) == 0, let bytes {
                let data = Data(bytesNoCopy: bytes, count: length, deallocator: .free)
                if var snapshot = try? JSONDecoder().decode(Self.self, from: data) {
                    snapshot.source = path
                    return snapshot
                }
            }
        }
        throw MonitorError.message("等待 Clash 内核。请启动 Clash Verge Rev 或 v2free。")
    }
}

struct Connection: Decodable {
    struct Metadata: Decodable {
        var process, processPath, host, sniffHost, destinationIP, network: String?
    }

    var id, start: String
    var metadata: Metadata
    var chains: [String]
    var rule, rulePayload: String?
    var upload, download: Int64

    var process: String {
        metadata.process.nonEmpty
            ?? metadata.processPath.nonEmpty.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? "未识别"
    }
    var host: String { metadata.host.nonEmpty ?? metadata.sniffHost.nonEmpty ?? metadata.destinationIP.nonEmpty ?? "未识别" }
    var node: String { chains.first ?? "未识别" }
    var matchedRule: String { [rule.nonEmpty, rulePayload.nonEmpty].compactMap { $0 }.joined(separator: " / ") }
}

extension Optional where Wrapped == String {
    var nonEmpty: String? { flatMap { $0.isEmpty ? nil : $0 } }
}

enum MonitorError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let value): return value }
    }
}

struct TrafficRow: Identifiable {
    var minute: Int64
    var connection, started, process, host, node, network, rule: String
    var upload, download: Int64
    var totalBytes: Int64 { upload + download }
    var totalMegabytes: Decimal { Decimal(totalBytes) / 1_000_000 }
    var id: String { "\(minute)/\(connection)" }
    var date: Date { Date(timeIntervalSince1970: Double(minute)) }
}

struct TrafficFilter: Equatable {
    var start = Calendar.current.startOfDay(for: Date())
    var end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
    var search = ""
    var proxyOnly = false
}

final class TrafficStore {
    static let retention: TimeInterval = 7 * 24 * 3600
    private let db: OpaquePointer

    init(at url: URL, readOnly: Bool = false) throws {
        var handle: OpaquePointer?
        let mode = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &handle, mode, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw MonitorError.message("无法打开本地记录数据库。")
        }
        sqlite3_busy_timeout(handle, 500)
        if !readOnly {
            let result = sqlite3_exec(handle, """
                PRAGMA journal_mode=WAL;
                PRAGMA secure_delete=ON;
                CREATE TABLE IF NOT EXISTS traffic (
                  minute INTEGER NOT NULL, connection TEXT NOT NULL, started TEXT NOT NULL,
                  process TEXT NOT NULL, host TEXT NOT NULL, node TEXT NOT NULL, network TEXT NOT NULL,
                  rule TEXT NOT NULL, upload INTEGER NOT NULL, download INTEGER NOT NULL,
                  PRIMARY KEY(minute, connection)
                ) WITHOUT ROWID;
                """, nil, nil, nil)
            guard result == SQLITE_OK else {
                sqlite3_close(handle)
                throw MonitorError.message("无法初始化本地数据库（SQLite \(result)）。")
            }
        }
        db = handle
    }

    deinit { sqlite3_close(db) }

    private func failure() -> MonitorError {
        .message("本地记录数据库错误（SQLite \(sqlite3_errcode(db))）。")
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    func prune(at now: Date) throws {
        let stmt = try prepare("DELETE FROM traffic WHERE minute < ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(now.timeIntervalSince1970 - Self.retention))
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
    }

    func record(_ current: Snapshot, after previous: Snapshot, at time: Date) throws {
        guard current.source == previous.source,
              current.uploadTotal >= previous.uploadTotal,
              current.downloadTotal >= previous.downloadTotal else { return }
        let before = Dictionary((previous.connections ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let minute = Int64(time.timeIntervalSince1970) / 60 * 60
        let changes = (current.connections ?? []).compactMap { connection -> (Connection, Int64, Int64)? in
            let upload = connection.upload - (before[connection.id]?.upload ?? 0)
            let download = connection.download - (before[connection.id]?.download ?? 0)
            return upload >= 0 && download >= 0 && (upload > 0 || download > 0) ? (connection, upload, download) : nil
        }
        guard !changes.isEmpty else { return }

        let stmt = try prepare("""
            INSERT INTO traffic VALUES (?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(minute, connection) DO UPDATE SET
              process=excluded.process, host=excluded.host, node=excluded.node,
              network=excluded.network, rule=excluded.rule,
              upload=upload+excluded.upload, download=download+excluded.download
            """)
        defer { sqlite3_finalize(stmt) }
        try exec("BEGIN IMMEDIATE")
        do {
            for (connection, upload, download) in changes {
                sqlite3_bind_int64(stmt, 1, minute)
                let text = [connection.id, connection.start, connection.process, connection.host, connection.node,
                            connection.metadata.network ?? "", connection.matchedRule]
                for (index, value) in text.enumerated() { bind(value, to: Int32(index + 2), in: stmt) }
                sqlite3_bind_int64(stmt, 9, upload)
                sqlite3_bind_int64(stmt, 10, download)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
                sqlite3_reset(stmt)
            }
            try exec("COMMIT")
        } catch {
            sqlite3_reset(stmt)
            try? exec("ROLLBACK")
            throw error
        }
    }

    func read(_ filter: TrafficFilter, limit: Int64, offset: Int64 = 0,
              onRow: (TrafficRow) throws -> Void) throws {
        let stmt = try prepare("""
            SELECT * FROM traffic WHERE minute >= ? AND minute < ?
              AND (? = '' OR instr(lower(host), lower(?)) OR instr(lower(process), lower(?))
                OR instr(lower(node), lower(?)) OR instr(lower(rule), lower(?)))
              AND (? = 0 OR node <> 'DIRECT')
            ORDER BY minute DESC, connection DESC LIMIT ? OFFSET ?
            """)
        defer { sqlite3_finalize(stmt) }
        let start = max(filter.start.timeIntervalSince1970, Date().timeIntervalSince1970 - Self.retention)
        sqlite3_bind_int64(stmt, 1, Int64(start.rounded(.up)))
        sqlite3_bind_int64(stmt, 2, Int64(filter.end.timeIntervalSince1970))
        for index in 3...7 { bind(filter.search, to: Int32(index), in: stmt) }
        sqlite3_bind_int(stmt, 8, filter.proxyOnly ? 1 : 0)
        sqlite3_bind_int64(stmt, 9, limit)
        sqlite3_bind_int64(stmt, 10, offset)
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_DONE: return
            case SQLITE_ROW:
                func text(_ column: Int32) -> String { String(cString: sqlite3_column_text(stmt, column)) }
                try onRow(TrafficRow(minute: sqlite3_column_int64(stmt, 0), connection: text(1), started: text(2),
                                     process: text(3), host: text(4), node: text(5), network: text(6), rule: text(7),
                                     upload: sqlite3_column_int64(stmt, 8), download: sqlite3_column_int64(stmt, 9)))
            default: throw failure()
            }
        }
    }
}

func csvText(_ input: String) -> String {
    // Excel and WPS can interpret quoted text beginning with formula markers.
    let stripped = input.drop(while: { $0.isWhitespace || $0.isNewline })
    let formula = stripped.first.map { "=+-@".contains($0) } ?? false
    let value = formula ? "'" + input : input
    return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}
