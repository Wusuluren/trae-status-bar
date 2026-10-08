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

/// 通用多来源日志监控器：同时监控 Trae / Qoder / Cursor 等多个 LogSource。
/// 监控各来源所有根目录下的"存活"会话目录，并为每个会话的每个窗口挂载日志 watcher。
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
        let key: String             // sessions 字典的唯一 key
        let source: any LogSource   // 所属 IDE 来源
        let path: String            // 会话目录绝对路径
        let dirName: String         // 目录末段，形如 20260929T161645（用于展示与解析时间）
        var windowPaths: Set<String> = []   // 已挂载的窗口日志路径
        var chatSessions: [String: ChatSessionInfo] = [:]
    }

    private var sessions: [String: SessionInfo] = [:]   // key -> info
    private var watchers: [String: FileWatcher] = [:]   // windowLogPath -> watcher
    private let sources: [any LogSource]
    private var baseDirWatchers: [DispatchSourceFileSystemObject] = []
    private var rescanTimer: Timer?

    var onSessionAdded: ((String) -> Void)?
    var onSessionRemoved: ((String) -> Void)?
    var onChatSessionStart: ((String, String) -> Void)?   // (sessionKey, chatId)
    var onChatSessionStop: ((String, String) -> Void)?

    var sessionKeys: [String] { sessions.keys.sorted() }

    func chatSessions(for key: String) -> [(id: String, info: ChatSessionInfo)] {
        guard let info = sessions[key] else { return [] }
        return info.chatSessions
            .map { (id: $0.key, info: $0.value) }
            .sorted { lhs, rhs in
                if lhs.info.isRunning != rhs.info.isRunning { return lhs.info.isRunning }
                return lhs.info.lastSeenAt > rhs.info.lastSeenAt
            }
    }

    /// 全局所有 chat session：有运行会话的来源排在前的分组序；同来源内运行中优先、
    /// 最近活跃在前；同应用启动会话连续排列（菜单分组直接顺序扫描）。
    func allChatSessions() -> [(sourceName: String, sessionId: String, dirName: String, chatId: String, info: ChatSessionInfo)] {
        var activeBySourceName: [String: Int] = [:]
        for s in sessions.values {
            let n = s.chatSessions.values.filter { $0.isRunning }.count
            activeBySourceName[s.source.displayName, default: 0] += n
        }
        var names: [String] = []
        var byName: [String: [(String, String, String, String, ChatSessionInfo)]] = [:]
        for key in sessionKeys {
            guard let s = sessions[key] else { continue }
            for (chatId, info) in sortedChatSessions(s) {
                byName[s.source.displayName, default: []].append((s.source.displayName, key, s.dirName, chatId, info))
                if !names.contains(s.source.displayName) { names.append(s.source.displayName) }
            }
        }
        // 来源分组排序：有运行会话的优先，其次组内最新活跃
        names.sort { a, b in
            let na = activeBySourceName[a] ?? 0, nb = activeBySourceName[b] ?? 0
            if (na > 0) != (nb > 0) { return na > 0 }
            let la = byName[a]?.first?.4.lastSeenAt ?? 0
            let lb = byName[b]?.first?.4.lastSeenAt ?? 0
            return la > lb
        }
        var out: [(String, String, String, String, ChatSessionInfo)] = []
        for name in names { out.append(contentsOf: byName[name] ?? []) }
        return out
    }

    private func sortedChatSessions(_ s: SessionInfo) -> [(String, ChatSessionInfo)] {
        // 运行中优先，其次最近活跃
        s.chatSessions.map { ($0.key, $0.value) }.sorted {
            if $0.1.isRunning != $1.1.isRunning { return $0.1.isRunning }
            return $0.1.lastSeenAt > $1.1.lastSeenAt
        }
    }

    /// 当前所有来源中处于流式输出状态的 chat session 总个数
    var activeSessionCount: Int {
        var n = 0
        for info in sessions.values {
            for cs in info.chatSessions.values where cs.isRunning { n += 1 }
        }
        return n
    }

    /// 某来源进行中的 chat session 个数（菜单分组 header 用）。按来源名匹配（各来源名字唯一）。
    func activeCount(forSourceNamed name: String) -> Int {
        var n = 0
        for info in sessions.values where info.source.displayName == name {
            for cs in info.chatSessions.values where cs.isRunning { n += 1 }
        }
        return n
    }

    /// 标题由外部（如 Cursor 索引库）异步写入，存量会话可能还没有；刷新前补一次解析。
    /// 来源实现 ChatTitleResolving 才生效。
    func resolveMissingTitles() {
        for key in sessions.keys {
            guard var info = sessions[key] else { continue }
            guard let resolver = info.source as? ChatTitleResolving else { continue }
            var mutated = false
            for (chatId, var cs) in info.chatSessions where cs.title.isEmpty {
                if let t = resolver.resolveTitle(chatId: chatId), !t.isEmpty {
                    cs.title = t
                    info.chatSessions[chatId] = cs
                    mutated = true
                }
            }
            if mutated { sessions[key] = info }
        }
    }

    init(sources: [any LogSource]) {
        self.sources = sources
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
        var liveKeys = Set<String>()

        for source in sources {
            // 进程存活探测按来源独立做（各 IDE 未必都带 --aha-log-session-time= 标志）
            var processLiveIds = Self.liveSessionIdsFromProcesses()

            for base in source.logsBases {
                guard let contents = try? fm.contentsOfDirectory(atPath: base) else { continue }
                let dirsWithWindows = contents
                    .filter(Self.isSessionDir)
                    .filter { Self.hasWindows(in: "\(base)/\($0)", prefix: source.windowDirPrefix) }

                // 进程标志可能指向已被轮转删除的旧目录（reload 后启动时间不变但目录名会变），
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
                        isLive = isSessionLive("\(base)/\(dirName)", source: source)
                    }
                    guard isLive else { continue }
                    let sessionPath = "\(base)/\(dirName)"
                    let key = "\(source.displayName)|\(sessionPath)"
                    liveKeys.insert(key)
                    if sessions[key] == nil {
                        sessions[key] = SessionInfo(key: key, source: source, path: sessionPath, dirName: dirName)
                        print("[agent-status-bar] Session added: \(key)")
                        DispatchQueue.main.async { [weak self] in self?.onSessionAdded?(key) }
                    }
                    refreshWindows(for: key)
                }
            }
        }

        let removed = sessions.keys.filter { !liveKeys.contains($0) }
        for key in removed {
            guard let info = sessions.removeValue(forKey: key) else { continue }
            for path in info.windowPaths { watchers.removeValue(forKey: path) }
            print("[agent-status-bar] Session removed (stale): \(key)")
            DispatchQueue.main.async { [weak self] in self?.onSessionRemoved?(key) }
        }
    }

    private func refreshWindows(for key: String) {
        guard let info = sessions[key] else { return }
        let source = info.source
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

            sessions[key]?.windowPaths.insert(logPath)
            let w = FileWatcher(path: logPath)
            w.onNewLines = { [weak self] content in
                self?.parseLines(content, key: key, logPath: logPath)
            }
            w.start()
            watchers[logPath] = w
            print("[agent-status-bar] Watching: \(logPath)")
            w.readAll()
        }

        let removedPaths = watchedPaths.subtracting(currentPaths)
        if !removedPaths.isEmpty {
            for path in removedPaths {
                sessions[key]?.windowPaths.remove(path)
                watchers.removeValue(forKey: path)
            }
            print("[agent-status-bar] Removed windows: \(removedPaths)")
        }
    }

    // MARK: 日志解析

    private func parseLines(_ content: String, key: String, logPath: String) {
        guard var info = sessions[key] else { return }
        let source = info.source
        var chatTransitions: [String: (wasRunning: Bool, nowRunning: Bool)] = [:]
        let now = Date().timeIntervalSince1970

        content.enumerateLines { line, _ in
            guard source.interestedIn(line) else { return }

            if let md = source.extractMetadata(from: line), let chatId = md.chatId {
                var cs = info.chatSessions[chatId] ?? ChatSessionInfo()
                cs.lastSeenAt = now
                if let t = md.title, !t.isEmpty { cs.title = t }
                if let w = md.workspacePath, !w.isEmpty { cs.workspacePath = w }
                if let c = md.createdAt { cs.createdAt = c }
                cs.seenInWindows.insert(logPath)
                info.chatSessions[chatId] = cs
            }

            if let ev = source.extractStreamEvent(from: line) {
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

        sessions[key] = info

        for (chatId, t) in chatTransitions {
            if t.nowRunning && !t.wasRunning {
                DispatchQueue.main.async { [weak self] in self?.onChatSessionStart?(key, chatId) }
            } else if !t.nowRunning && t.wasRunning {
                DispatchQueue.main.async { [weak self] in self?.onChatSessionStop?(key, chatId) }
            }
        }
    }

    // MARK: 看门狗

    private func sweepStaleStreams() -> Bool {
        let now = Date()
        var changed = false
        let liveWindowPaths = Set(watchers.keys)

        for key in sessions.keys {
            guard var info = sessions[key] else { continue }
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

            if mutated { sessions[key] = info; changed = true }
            for chatId in stopChatIds {
                DispatchQueue.main.async { [weak self] in self?.onChatSessionStop?(key, chatId) }
            }
        }
        return changed
    }

    // MARK: 存活判定

    private func isSessionLive(_ sessionPath: String, source: any LogSource) -> Bool {
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
        for source in sources {
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
