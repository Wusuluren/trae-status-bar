import Foundation

// MARK: - 配置
enum Config {
    /// 会话目录被视为"存活"的最大静默时间
    static let sessionStaleThreshold: TimeInterval = 6 * 3600
    /// 目录重扫间隔（秒）
    static let rescanInterval: TimeInterval = 5
    /// 看门狗：窗口运行中但其日志持续这么久无任何写入则强制复位为空闲
    static let streamStallTimeout: TimeInterval = 300
    /// 窗口日志超过这么久无写入视为已关闭窗口
    static let windowStaleThreshold: TimeInterval = 24 * 3600
}

/// 通用多会话日志监控器（与具体 IDE 解耦，靠 LogSource 抽象差异）。
/// 监控所有根目录下的"存活"会话目录，并为每个会话的每个窗口挂载日志 watcher。
/// 所有回调均在主线程派发。
final class LogMonitor {
    /// 业务层 chat session（一次 AI 对话）。
    struct ChatSessionInfo {
        var title: String = ""
        var workspacePath: String = ""
        var createdAt: Date? = nil
        /// 仍在哪些 windowLogPath 上跑（跨窗口共享 stream 事件去重）
        var runningWindows: Set<String> = []
        /// 看到过该 chat session 的窗口集合（窗口消失时 GC）
        var seenInWindows: Set<String> = []
        var lastSeenAt: TimeInterval = 0
        var isRunning: Bool { !runningWindows.isEmpty }
        var displayName: String {
            if !title.isEmpty { return title }
            if !workspacePath.isEmpty { return (workspacePath as NSString).lastPathComponent }
            return "会话"
        }
        var workspaceShort: String? {
            workspacePath.isEmpty ? nil : (workspacePath as NSString).lastPathComponent
        }
    }

    struct SessionInfo {
        let path: String        // 会话目录绝对路径（唯一 key）
        let dirName: String     // 目录末段，形如 20260929T161645（用于展示与解析时间）
        var windowPaths: Set<String> = []   // 已挂载的窗口日志路径
        var chatSessions: [String: ChatSessionInfo] = [:]
    }

    private var sessions: [String: SessionInfo] = [:]   // sessionPath -> info
    private var watchers: [String: FileWatcher] = [:]   // windowLogPath -> watcher
    private let source: LogSource
    private var baseDirWatchers: [DispatchSourceFileSystemObject] = []
    private var rescanTimer: Timer?

    /// 由外部注入：composerId -> 会话标题。renderer.log 不带标题，需要查 Cursor 的对话索引库。
    var titleResolver: ((String) -> String?)?

    var onSessionAdded: ((String) -> Void)?
    var onSessionRemoved: ((String) -> Void)?
    var onChatSessionStart: ((String, String) -> Void)?   // (sessionPath, chatId)
    var onChatSessionStop: ((String, String) -> Void)?

    var sessionPaths: [String] { sessions.keys.sorted() }

    func chatSessions(for sessionPath: String) -> [(id: String, info: ChatSessionInfo)] {
        guard let info = sessions[sessionPath] else { return [] }
        return info.chatSessions
            .map { (id: $0.key, info: $0.value) }
            .sorted { lhs, rhs in
                if lhs.info.isRunning != rhs.info.isRunning { return lhs.info.isRunning }
                return lhs.info.lastSeenAt > rhs.info.lastSeenAt
            }
    }

    func allChatSessions() -> [(sessionId: String, chatId: String, info: ChatSessionInfo)] {
        var out: [(String, String, ChatSessionInfo)] = []
        for sid in sessionPaths {
            for (chatId, info) in sessions[sid]?.chatSessions ?? [:] {
                out.append((sid, chatId, info))
            }
        }
        out.sort { lhs, rhs in
            if lhs.2.isRunning != rhs.2.isRunning { return lhs.2.isRunning }
            return lhs.2.lastSeenAt > rhs.2.lastSeenAt
        }
        return out
    }

    var activeSessionCount: Int {
        var n = 0
        for info in sessions.values {
            for cs in info.chatSessions.values where cs.isRunning { n += 1 }
        }
        return n
    }

    /// 标题由 Cursor 侧异步写入索引库，存量会话可能还没有；刷新前补一次解析。
    func resolveMissingTitles() {
        guard let resolve = titleResolver else { return }
        for sessionPath in sessions.keys {
            guard var info = sessions[sessionPath] else { continue }
            var mutated = false
            for (chatId, var cs) in info.chatSessions where cs.title.isEmpty {
                if let t = resolve(chatId), !t.isEmpty {
                    cs.title = t
                    info.chatSessions[chatId] = cs
                    mutated = true
                }
            }
            if mutated { sessions[sessionPath] = info }
        }
    }

    init(source: LogSource) {
        self.source = source
    }

    func start() {
        scanAndWatch()
        watchBaseDirs()
        rescanTimer = Timer.scheduledTimer(withTimeInterval: Config.rescanInterval, repeats: true) { [weak self] _ in
            self?.scanAndWatch()
            self?.checkWatcherRotation()
            _ = self?.sweepStaleStreams()
        }
    }

    private func checkWatcherRotation() {
        for watcher in watchers.values { watcher.reopenIfNeeded() }
    }

    // MARK: 扫描

    private func scanAndWatch() {
        let fm = FileManager.default
        var livePaths = Set<String>()
        // 进程存活探测做一次即可（ps 全表扫描较贵）
        var processLiveIds = Self.liveSessionIdsFromProcesses()

        for base in source.logsBases {
            guard let contents = try? fm.contentsOfDirectory(atPath: base) else { continue }
            let dirsWithWindows = contents
                .filter(Self.isSessionDir)
                .filter { Self.hasWindows(in: "\(base)/\($0)", prefix: source.windowDirPrefix) }

            // 进程标志可能指向已被轮转删除的旧目录（Qoder reload 后启动时间不变但目录名会变），
            // 也可能混入 ps 自匹配的垃圾串。与真实存在的会话目录求交，交集为空则回退 mtime 启发式。
            if let ids = processLiveIds {
                let valid = ids.intersection(dirsWithWindows)
                processLiveIds = valid.isEmpty ? nil : valid
            }

            for dirName in dirsWithWindows {
                let isLive: Bool
                if let ids = processLiveIds {
                    isLive = ids.contains(dirName)
                } else {
                    isLive = isSessionLive("\(base)/\(dirName)")
                }
                guard isLive else { continue }
                let sessionPath = "\(base)/\(dirName)"
                livePaths.insert(sessionPath)
                if sessions[sessionPath] == nil {
                    sessions[sessionPath] = SessionInfo(path: sessionPath, dirName: dirName)
                    print("[cursor-status-bar] Session added: \(sessionPath)")
                    DispatchQueue.main.async { [weak self] in self?.onSessionAdded?(sessionPath) }
                }
                refreshWindows(for: sessionPath)
            }
        }

        let removed = sessions.keys.filter { !livePaths.contains($0) }
        for sessionPath in removed {
            guard let info = sessions.removeValue(forKey: sessionPath) else { continue }
            for path in info.windowPaths { watchers.removeValue(forKey: path) }
            print("[cursor-status-bar] Session removed (stale): \(sessionPath)")
            DispatchQueue.main.async { [weak self] in self?.onSessionRemoved?(sessionPath) }
        }
    }

    private func refreshWindows(for sessionPath: String) {
        guard let info = sessions[sessionPath] else { return }
        let fm = FileManager.default
        guard let windows = try? fm.contentsOfDirectory(atPath: info.path)
            .filter({ $0.hasPrefix(source.windowDirPrefix) }) else { return }

        let watchedPaths = info.windowPaths
        var currentPaths = Set<String>()

        for window in windows {
            let logPath = "\(info.path)/\(window)/\(source.windowLogFileName)"
            guard fm.fileExists(atPath: logPath) else { continue }
            if Date().timeIntervalSince(fileModificationDate(logPath)) > Config.windowStaleThreshold { continue }
            currentPaths.insert(logPath)
            if watchedPaths.contains(logPath) { continue }

            sessions[sessionPath]?.windowPaths.insert(logPath)
            let w = FileWatcher(path: logPath)
            w.onNewLines = { [weak self] content in
                self?.parseLines(content, sessionPath: sessionPath, logPath: logPath)
            }
            w.start()
            watchers[logPath] = w
            print("[cursor-status-bar] Watching: \(logPath)")
            w.readAll()
        }

        let removedPaths = watchedPaths.subtracting(currentPaths)
        if !removedPaths.isEmpty {
            for path in removedPaths {
                sessions[sessionPath]?.windowPaths.remove(path)
                watchers.removeValue(forKey: path)
            }
            print("[cursor-status-bar] Removed windows: \(removedPaths)")
        }
    }

    // MARK: 日志解析

    private func parseLines(_ content: String, sessionPath: String, logPath: String) {
        guard var info = sessions[sessionPath] else { return }
        var chatTransitions: [String: (wasRunning: Bool, nowRunning: Bool)] = [:]
        let now = Date().timeIntervalSince1970

        content.enumerateLines { line, _ in
            guard self.source.interestedIn(line) else { return }

            if let md = self.source.extractMetadata(from: line), let chatId = md.chatId {
                var cs = info.chatSessions[chatId] ?? ChatSessionInfo()
                cs.lastSeenAt = now
                if let t = md.title, !t.isEmpty { cs.title = t }
                if let w = md.workspacePath, !w.isEmpty { cs.workspacePath = w }
                if let c = md.createdAt { cs.createdAt = c }
                cs.seenInWindows.insert(logPath)
                info.chatSessions[chatId] = cs
            }

            if let ev = self.source.extractStreamEvent(from: line) {
                var cs = info.chatSessions[ev.chatId] ?? ChatSessionInfo()
                let wasRunning = cs.isRunning
                cs.lastSeenAt = now
                cs.seenInWindows.insert(logPath)
                switch ev.kind {
                case .start: cs.runningWindows.insert(logPath)
                case .stop:  cs.runningWindows.remove(logPath)
                }
                let nowRunning = cs.isRunning
                info.chatSessions[ev.chatId] = cs
                if wasRunning != nowRunning {
                    chatTransitions[ev.chatId] = (wasRunning, nowRunning)
                }
            }
        }

        sessions[sessionPath] = info

        for (chatId, t) in chatTransitions {
            if t.nowRunning && !t.wasRunning {
                DispatchQueue.main.async { [weak self] in self?.onChatSessionStart?(sessionPath, chatId) }
            } else if !t.nowRunning && t.wasRunning {
                DispatchQueue.main.async { [weak self] in self?.onChatSessionStop?(sessionPath, chatId) }
            }
        }
    }

    // MARK: 看门狗

    private func sweepStaleStreams() -> Bool {
        let now = Date()
        var changed = false
        let liveWindowPaths = Set(watchers.keys)

        for sessionPath in sessions.keys {
            guard var info = sessions[sessionPath] else { continue }
            var mutated = false
            var stopChatIds: [String] = []

            for (chatId, var cs) in info.chatSessions {
                let before = cs.isRunning
                cs.runningWindows = cs.runningWindows.filter { wPath in
                    now.timeIntervalSince(fileModificationDate(wPath)) <= Config.streamStallTimeout
                }
                let prunedSeen = cs.seenInWindows.intersection(liveWindowPaths)
                if prunedSeen != cs.seenInWindows { cs.seenInWindows = prunedSeen }
                let after = cs.isRunning
                if before != after {
                    info.chatSessions[chatId] = cs
                    if before && !after { stopChatIds.append(chatId) }
                    mutated = true
                } else if !cs.runningWindows.isEmpty || prunedSeen != cs.seenInWindows {
                    info.chatSessions[chatId] = cs
                }
            }

            if mutated { sessions[sessionPath] = info; changed = true }
            for chatId in stopChatIds {
                DispatchQueue.main.async { [weak self] in self?.onChatSessionStop?(sessionPath, chatId) }
            }
        }
        return changed
    }

    // MARK: 存活判定

    private func isSessionLive(_ sessionPath: String) -> Bool {
        let now = Date()
        let fm = FileManager.default
        func recent(_ date: Date?) -> Bool {
            guard let date else { return false }
            return now.timeIntervalSince(date) < Config.sessionStaleThreshold
        }
        if let items = try? fm.contentsOfDirectory(atPath: sessionPath) {
            for item in items {
                let p = "\(sessionPath)/\(item)"
                if let attrs = try? fm.attributesOfItem(atPath: p),
                   let d = attrs[.modificationDate] as? Date, recent(d) { return true }
            }
        }
        if let windows = try? fm.contentsOfDirectory(atPath: sessionPath).filter({ $0.hasPrefix(source.windowDirPrefix) }) {
            for w in windows {
                let p = "\(sessionPath)/\(w)/\(source.windowLogFileName)"
                if let attrs = try? fm.attributesOfItem(atPath: p),
                   let d = attrs[.modificationDate] as? Date, recent(d) { return true }
            }
        }
        return false
    }

    private func fileModificationDate(_ path: String) -> Date {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let d = attrs[.modificationDate] as? Date else { return Date.distantPast }
        return d
    }

    // MARK: 目录监听

    private func watchBaseDirs() {
        let fm = FileManager.default
        for base in source.logsBases where fm.fileExists(atPath: base) {
            guard let handle = FileHandle(forReadingAtPath: base) else { continue }
            let dispatchSource = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: handle.fileDescriptor,
                eventMask: [.write, .rename, .delete, .extend],
                queue: .main
            )
            dispatchSource.setEventHandler { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self?.scanAndWatch() }
            }
            dispatchSource.resume()
            baseDirWatchers.append(dispatchSource)
        }
    }

    // MARK: 进程存活探测

    private static let sessionPattern = try! NSRegularExpression(pattern: #"^\d{8}T\d{6}$"#)

    private static func liveSessionIdsFromProcesses() -> Set<String>? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return nil }
        let ids = out.split(separator: "\n").compactMap { line -> String? in
            guard let range = line.range(of: "--aha-log-session-time=") else { return nil }
            let value = line[range.upperBound...].prefix(15)
            return value.isEmpty ? nil : String(value)
        }
        return ids.isEmpty ? nil : Set(ids)
    }

    private static func isSessionDir(_ name: String) -> Bool {
        sessionPattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    private static func hasWindows(in sessionPath: String, prefix: String) -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: sessionPath) else { return false }
        return items.contains { $0.hasPrefix(prefix) }
    }

    deinit {
        for w in baseDirWatchers { w.cancel() }
        rescanTimer?.invalidate()
    }
}
