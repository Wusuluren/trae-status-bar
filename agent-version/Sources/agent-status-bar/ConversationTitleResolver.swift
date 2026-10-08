import Foundation

// MARK: - libsqlite3 直接声明
/// 会话标题来源是 Cursor 全局对话索引库的只读查询。
/// 不 import SQLite3 module：本机 /usr/local/include 的同名头与 SDK 头冲突会编译失败，
/// 这里直接声明 C 符号，swiftc 链接 libsqlite3.tbd。
private let SQLITE_OK: Int32 = 0
private let SQLITE_ROW: Int32 = 100
private let SQLITE_OPEN_READONLY: Int32 = 0x00000001
private let SQLITE_OPEN_NOMUTATE: Int32 = 0x00008000
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private typealias sqlite3 = OpaquePointer
private typealias sqlite3_stmt = OpaquePointer
typealias sqlite3_destructor_type = @convention(c) (UnsafeMutableRawPointer?) -> Void

@_silgen_name("sqlite3_open_v2")
private func sqlite3_open_v2(_ filename: UnsafePointer<CChar>?, _ db: UnsafeMutablePointer<OpaquePointer?>, _ flags: Int32, _ vfs: UnsafePointer<CChar>?) -> Int32

@_silgen_name("sqlite3_close")
private func sqlite3_close(_ db: OpaquePointer?) -> Int32

@_silgen_name("sqlite3_prepare_v2")
private func sqlite3_prepare_v2(_ db: OpaquePointer?, _ sql: UnsafePointer<CChar>, _ nByte: Int32, _ stmt: UnsafeMutablePointer<OpaquePointer?>, _ tail: UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32

@_silgen_name("sqlite3_bind_text")
private func sqlite3_bind_text(_ stmt: OpaquePointer?, _ idx: Int32, _ text: UnsafePointer<CChar>, _ n: Int32, _ destructor: sqlite3_destructor_type?) -> Int32

@_silgen_name("sqlite3_step")
private func sqlite3_step(_ stmt: OpaquePointer?) -> Int32

@_silgen_name("sqlite3_column_text")
private func sqlite3_column_text(_ stmt: OpaquePointer?, _ col: Int32) -> UnsafePointer<UInt8>?

@_silgen_name("sqlite3_finalize")
private func sqlite3_finalize(_ stmt: OpaquePointer?) -> Int32

/// composerId -> 会话标题。renderer.log 只记 composerId，人类可读标题由 Cursor 的
/// ConversationSearch 写进全局 `conversation-search.db` 的 `conversations(id, title)`。
/// 只读查询；库缺失/未索引时返回 nil，展示层回退短 id。
final class ConversationTitleResolver {
    private let dbPath: String
    private var db: OpaquePointer?
    private var cache: [String: String] = [:]

    private static let cacheLimit = 2000

    init?(defaultPath: String? = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true)
        .first.map { "\($0)/Cursor/User/globalStorage/conversation-search.db" }) {
        guard let path = defaultPath, !path.isEmpty else { return nil }
        self.dbPath = path
        guard openDB() else { return nil }
    }

    private func openDB() -> Bool {
        var handle: OpaquePointer?
        let result = dbPath.withCString { ptr in
            sqlite3_open_v2(ptr, &handle, Int32(SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTATE), nil)
        }
        guard result == SQLITE_OK, let h = handle else {
            if let handle { sqlite3_close(handle) }
            return false
        }
        db = h
        return true
    }

    /// 查不到返回 nil（未索引 / 空标题 / 库被重建）。结果按 id 缓存，避免每次刷新菜单都打库。
    func title(for composerId: String) -> String? {
        if let cached = cache[composerId] { return cached }
        guard let db else { return nil }

        let sql = "SELECT title FROM conversations WHERE id = ? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }

        composerId.withCString { ptr in
            sqlite3_bind_text(stmt, 1, ptr, -1, SQLITE_TRANSIENT)
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let text = sqlite3_column_text(stmt, 0) else { return nil }
        let title = String(cString: text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        if cache.count >= Self.cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[composerId] = title
        print("[agent-status-bar] Resolved title: \(composerId.prefix(8)) -> \(title)")
        return title
    }

    deinit {
        if let db { sqlite3_close(db) }
    }
}

// MARK: - ChatTitleResolving
/// 供 LogMonitor 动态检测注入：Cursor 的 renderer.log 不带标题，
/// 菜单刷新时对缺标题的会话补一次索引库查询。
extension ConversationTitleResolver: ChatTitleResolving {
    func resolveTitle(chatId: String) -> String? {
        title(for: chatId)
    }
}
