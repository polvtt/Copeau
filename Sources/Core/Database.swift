import Foundation
import SQLite3

/// Enveloppe minimale autour de SQLite (libsqlite3 du système, aucune dépendance).
final class Database {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    enum Value {
        case text(String?), int(Int), real(Double)
    }

    init(path: String) throws {
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            throw DBError.open(String(cString: sqlite3_errmsg(db)))
        }
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
    }

    /// Base en mémoire (mode démonstration / instantanés).
    init() {
        sqlite3_open(":memory:", &db)
    }

    deinit { sqlite3_close(db) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw DBError.query(msg)
        }
    }

    @discardableResult
    func run(_ sql: String, _ args: [Value] = []) throws -> Int {
        let st = try prepare(sql, args)
        defer { sqlite3_finalize(st) }
        let rc = sqlite3_step(st)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw DBError.query(String(cString: sqlite3_errmsg(db))) }
        return Int(sqlite3_changes(db))
    }

    func query(_ sql: String, _ args: [Value] = [], row: (Row) -> Void) throws {
        let st = try prepare(sql, args)
        defer { sqlite3_finalize(st) }
        while sqlite3_step(st) == SQLITE_ROW { row(Row(st: st)) }
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN")
        do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }

    var userVersion: Int {
        get { var v = 0; try? query("PRAGMA user_version") { v = $0.int(0) }; return v }
        set { try? exec("PRAGMA user_version = \(newValue)") }
    }

    private func prepare(_ sql: String, _ args: [Value]) throws -> OpaquePointer? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            throw DBError.query(String(cString: sqlite3_errmsg(db)) + " — " + sql)
        }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case .text(let s?): sqlite3_bind_text(st, idx, s, -1, Self.transient)
            case .text(nil): sqlite3_bind_null(st, idx)
            case .int(let v): sqlite3_bind_int64(st, idx, Int64(v))
            case .real(let v): sqlite3_bind_double(st, idx, v)
            }
        }
        return st
    }

    struct Row {
        let st: OpaquePointer?
        func text(_ i: Int32) -> String? {
            guard sqlite3_column_type(st, i) != SQLITE_NULL, let c = sqlite3_column_text(st, i) else { return nil }
            return String(cString: c)
        }
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(st, i)) }
        func real(_ i: Int32) -> Double { sqlite3_column_double(st, i) }
    }

    enum DBError: Error, CustomStringConvertible {
        case open(String), query(String)
        var description: String {
            switch self { case .open(let m): "ouverture : \(m)"; case .query(let m): "requête : \(m)" }
        }
    }
}
