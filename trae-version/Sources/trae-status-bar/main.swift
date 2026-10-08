import AppKit
import Foundation

// MARK: - 配置
enum Config {
    /// 会话目录被视为"存活"的最大静默时间（该会话所有文件无任何日志写入则视为已关闭）
    static let sessionStaleThreshold: TimeInterval = 6 * 3600
    /// 目录重扫间隔（秒）
    static let rescanInterval: TimeInterval = 5
    /// 新挂载 watcher 时回读文件尾部的字节数，用于初始化窗口的流状态
    static let tailBytes: Int = 20_000
    /// 看门狗：一个窗口处于"运行中"但其 renderer.log 文件持续这么久没有任何写入，则强制复位为空闲。
    /// 活跃判定用文件修改时间（任何日志写入都算），避免因 chatStreamService 心跳行较长静默而误杀仍在进行的会话。
    /// 用于兜底各种未识别的异常结束路径（如仅打印 stream.onError / 直接中断）导致的状态卡死。
    static let streamStallTimeout: TimeInterval = 300
    /// 窗口日志超过这么久没有任何写入，视为已关闭窗口：不监听、不在菜单展示。
    /// Trae 关闭窗口后不删除其 windowN 日志目录，需按 mtime 过滤历史残留。
    static let windowStaleThreshold: TimeInterval = 24 * 3600
    /// Trae 日志根目录
    static let logsBase = "/Users/wav/Library/Application Support/Trae CN/logs"
}

// MARK: - 单文件监听器
class FileWatcher {
    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var currentInode: UInt64 = 0
    let path: String
    var onNewLines: ((String) -> Void)?

    init(path: String) {
        self.path = path
    }

    func start() {
        openFile(seekToEnd: true)
    }

    /// 回读文件尾部内容（用于新挂载时初始化状态，避免漏掉已经开始的流）
    func readTail(_ byteCount: Int) {
        guard let handle = fileHandle else { return }
        let length = handle.seekToEndOfFile()
        let start = length > UInt64(byteCount) ? length - UInt64(byteCount) : 0
        handle.seek(toFileOffset: start)
        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty, let content = String(data: data, encoding: .utf8) else { return }
        onNewLines?(content)
    }

    /// 轮询式轮转恢复：renderer.log 写满 10MB 会被 rename 成 renderer.1.log 并新建同名文件。
    /// 旧 fd 指向被换走的 inode，永远收不到写入事件，事件驱动的 checkRotation 因此永不触发，
    /// watcher 永久失联（状态卡死在 running 的根因）。由定时器每 5 秒调用本方法兜底。
    func reopenIfNeeded() {
        guard let newInode = Self.getInode(path), newInode != currentInode else { return }
        // 排空旧文件残余，避免轮转瞬间写入的尾部 marker 丢失
        if let handle = fileHandle {
            let data = handle.readDataToEndOfFile()
            if let content = String(data: data, encoding: .utf8), !content.isEmpty {
                onNewLines?(content)
            }
        }
        openFile(seekToEnd: false)
        guard let handle = fileHandle else { return }
        // 新文件从头重放一次，恢复轮转期间错过的 start/end 序列
        let data = handle.readDataToEndOfFile()
        if let content = String(data: data, encoding: .utf8), !content.isEmpty {
            onNewLines?(content)
        }
    }

    private func openFile(seekToEnd: Bool) {
        source?.cancel()
        fileHandle?.closeFile()

        guard FileManager.default.fileExists(atPath: path) else { return }
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        if seekToEnd { handle.seekToEndOfFile() }
        self.fileHandle = handle
        self.currentInode = Self.getInode(path) ?? 0

        let fd = handle.fileDescriptor
        let dispatchSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.extend, .write],
            queue: .main
        )
        dispatchSource.setEventHandler { [weak self] in
            self?.handleEvent()
        }
        dispatchSource.resume()
        self.source = dispatchSource
    }

    private func handleEvent() {
        checkRotation()
        guard let handle = fileHandle else { return }
        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty, let content = String(data: data, encoding: .utf8) else { return }
        onNewLines?(content)
    }

    private func checkRotation() {
        guard let newInode = Self.getInode(path), newInode != currentInode else { return }
        openFile(seekToEnd: false)
    }

    private static func getInode(_ path: String) -> UInt64? {
        var statBuf = stat()
        guard stat(path, &statBuf) == 0 else { return nil }
        return statBuf.st_ino
    }

    deinit {
        source?.cancel()
        fileHandle?.closeFile()
    }
}

// MARK: - 多会话日志监控器
/// 监控 logs 根目录下的所有"存活"会话目录（每个会话目录 = Trae 的一次应用实例/会话），
/// 并为每个会话内的每个 window 挂载 renderer.log watcher。
/// 所有回调均在主线程派发，按 sessionId 区分。
class TraeLogMonitor {
    /// Trae 业务层的 chat session（一次 AI 对话 = 一个 chat session；多个 Trae 窗口可共享）。
    /// 名字（title / workspace basename）从 renderer.log 的 Session fetched/updated 事件提取。
    struct ChatSessionInfo {
        var title: String = ""           // Session updated 携带的标题
        var workspacePath: String = ""   // Session fetched 携带的工作区路径
        var createdAt: Date? = nil       // Session fetched 的 created_at（毫秒）
        /// 仍在哪些 windowPath 上跑（用于跨窗口共享 stream 事件的去重）
        var runningWindows: Set<String> = []
        /// 看到过该 chat session 的 window 集合（用于窗口消失时 GC）
        var seenInWindows: Set<String> = []
        /// 最后一次看到该 chat session 的时间戳（用于在菜单中排序与陈旧 GC）
        var lastSeenAt: TimeInterval = 0
        var isRunning: Bool { !runningWindows.isEmpty }
        /// 显示名：title > workspace basename > 短 ID
        var displayName: String {
            if !title.isEmpty { return title }
            if !workspacePath.isEmpty {
                return (workspacePath as NSString).lastPathComponent
            }
            return "会话"
        }
        /// 工作区短名（用于菜单前缀），空时返回 nil
        var workspaceShort: String? {
            workspacePath.isEmpty ? nil : (workspacePath as NSString).lastPathComponent
        }
        /// 用于兜底的短 ID（取末尾 6 位）。短 ID 是基于 chat_session_id 生成的，
        /// 由调用方在拿到 chatSessionId 后用 `String(chatSessionId.suffix(6))` 自取，
        /// 这里不再放在 struct 里（struct 自身没有 chat_session_id 字段）。
    }

    struct SessionInfo {
        var path: String
        var windowStates: [String: Bool] = [:] // windowLogPath -> isRunning（按 window 粒度的流状态，保留）
        /// chatSessionId -> chat session 元数据与流状态
        var chatSessions: [String: ChatSessionInfo] = [:]
    }

    private var sessions: [String: SessionInfo] = [:] // appSessionId -> info
    private var watchers: [String: FileWatcher] = [:] // windowLogPath -> watcher
    private let logsBase: String
    private var baseDirWatcher: DispatchSourceFileSystemObject?
    private var rescanTimer: Timer?

    // 应用启动级回调（主线程）—— 应用启动（Trae 一次运行）出现 / 消失
    var onSessionAdded: ((String) -> Void)?    // appSessionId
    var onSessionRemoved: ((String) -> Void)?  // appSessionId
    /// chat session 级回调 —— chat session 从 idle 切到 running
    var onChatSessionStart: ((String, String) -> Void)?  // (appSessionId, chatSessionId)
    /// chat session 级回调 —— chat session 从 running 切到 idle（且当前仍存在）
    var onChatSessionStop: ((String, String) -> Void)?   // (appSessionId, chatSessionId)

    /// 应用启动级会话 id 列表（用于扫描/分组）
    var sessionIds: [String] { sessions.keys.sorted() }

    /// 某应用启动下所有 chat session，按"运行中优先 + 最近活跃"排序
    func chatSessions(for appSessionId: String) -> [(id: String, info: ChatSessionInfo)] {
        guard let info = sessions[appSessionId] else { return [] }
        return info.chatSessions
            .map { (id: $0.key, info: $0.value) }
            .sorted { lhs, rhs in
                if lhs.info.isRunning != rhs.info.isRunning { return lhs.info.isRunning }
                return lhs.info.lastSeenAt > rhs.info.lastSeenAt
            }
    }

    /// 全局所有 chat session（去重，按应用启动分组；用于展示汇总或直接平铺）
    func allChatSessions() -> [(appSessionId: String, chatId: String, info: ChatSessionInfo)] {
        var out: [(String, String, ChatSessionInfo)] = []
        for appId in sessionIds {
            for (chatId, info) in sessions[appId]?.chatSessions ?? [:] {
                out.append((appId, chatId, info))
            }
        }
        out.sort { lhs, rhs in
            if lhs.2.isRunning != rhs.2.isRunning { return lhs.2.isRunning }
            return lhs.2.lastSeenAt > rhs.2.lastSeenAt
        }
        return out
    }

    /// 当前所有 chat session 中处于流式输出状态的个数
    var activeSessionCount: Int {
        var n = 0
        for info in sessions.values {
            for cs in info.chatSessions.values where cs.isRunning { n += 1 }
        }
        return n
    }

    init(logsBase: String) {
        self.logsBase = logsBase
    }

    func start() {
        scanAndWatch()
        watchBaseDir()
        rescanTimer = Timer.scheduledTimer(withTimeInterval: Config.rescanInterval, repeats: true) { [weak self] _ in
            self?.scanAndWatch()
            // 轮转自愈：renderer.log 滚动后旧 fd 失联，轮询 inode 重新挂载
            self?.checkWatcherRotation()
            // 看门狗：把僵死的 running 窗口复位为空闲（5 秒一次，远小于阈值）
            _ = self?.sweepStaleStreams()
        }
    }

    private func checkWatcherRotation() {
        for watcher in watchers.values {
            watcher.reopenIfNeeded()
        }
    }

    // MARK: 扫描

    private func scanAndWatch() {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: logsBase) else { return }

        // 优先以运行中的 Trae 进程参数为准（--aha-log-session-time=YYYYMMDDTHHMMSS），
        // 避免 Trae 启动/退出时回写历史会话目录的 mtime 把已关闭会话误判为存活。
        let processLiveIds = Self.liveSessionIdsFromProcesses()
        let live = contents
            .filter(Self.isSessionDir)
            .filter { Self.hasWindows(in: "\(logsBase)/\($0)") }
            .filter { sessionId in
                if let ids = processLiveIds {
                    return ids.contains(sessionId)
                }
                return isSessionLive("\(logsBase)/\(sessionId)")
            }
            .sorted()
        let liveSet = Set(live)

        // 新增会话
        for sessionId in live {
            if sessions[sessionId] == nil {
                sessions[sessionId] = SessionInfo(path: "\(logsBase)/\(sessionId)")
                print("[trae-status-bar] Session added: \(sessionId)")
                DispatchQueue.main.async { [weak self] in
                    self?.onSessionAdded?(sessionId)
                }
            }
            refreshWindows(for: sessionId)
        }

        // 移除消失/过期会话
        let removed = sessions.keys.filter { !liveSet.contains($0) }
        for sessionId in removed {
            guard let info = sessions.removeValue(forKey: sessionId) else { continue }
            for path in info.windowStates.keys {
                watchers.removeValue(forKey: path) // 释放 watcher（deinit 会取消 source）
            }
            print("[trae-status-bar] Session removed (stale): \(sessionId)")
            DispatchQueue.main.async { [weak self] in
                self?.onSessionRemoved?(sessionId)
            }
        }
    }

    private func refreshWindows(for sessionId: String) {
        guard sessions[sessionId] != nil else { return }
        let sessionPath = sessions[sessionId]!.path
        guard let windows = try? FileManager.default.contentsOfDirectory(atPath: sessionPath)
            .filter({ $0.hasPrefix("window") }) else { return }

        let watchedPaths = Set(sessions[sessionId]!.windowStates.keys)
        var currentPaths = Set<String>()

        for window in windows {
            let logPath = "\(sessionPath)/\(window)/renderer.log"
            guard FileManager.default.fileExists(atPath: logPath) else { continue }
            // 长期无写入的窗口目录视为已关闭窗口，跳过挂载（已监听的会经 removedPaths 移除）
            if Date().timeIntervalSince(fileModificationDate(logPath)) > Config.windowStaleThreshold { continue }
            currentPaths.insert(logPath)

            if watchedPaths.contains(logPath) { continue }

            // 就地登记为空闲；随后 readTail -> parseLines 会直接就地更新 sessions[sessionId]
            // 的 running 状态。这里绝不能用快照覆盖回去，否则会冲掉 parseLines 已写入的
            // "运行中" 状态（这是"正在输出却不转圈/显示空闲"的根因）。
            sessions[sessionId]?.windowStates[logPath] = false
            let w = FileWatcher(path: logPath)
            w.onNewLines = { [weak self] content in
                self?.parseLines(content, sessionId: sessionId, logPath: logPath)
            }
            w.start()
            watchers[logPath] = w
            print("[trae-status-bar] Watching: \(logPath)")
            // 回读尾部，初始化窗口状态，避免漏掉已开始的流（就地更新 sessions[sessionId]）
            w.readTail(Config.tailBytes)
        }

        // 移除已删除的窗口（就地修改）
        let removedPaths = watchedPaths.subtracting(currentPaths)
        if !removedPaths.isEmpty {
            for path in removedPaths {
                sessions[sessionId]?.windowStates.removeValue(forKey: path)
                watchers.removeValue(forKey: path)
            }
            print("[trae-status-bar] Removed windows: \(removedPaths)")
        }
    }

    // MARK: 日志解析

    private func parseLines(_ content: String, sessionId: String, logPath: String) {
        guard var info = sessions[sessionId] else { return }
        var currentState = info.windowStates[logPath] ?? false
        var toggled = false

        // chat session 维度：本批新事件里出现的 chatSessionId -> (wasRunning, nowRunning)
        var chatTransitions: [String: (wasRunning: Bool, nowRunning: Bool)] = [:]
        // 累计本批事件中"应该被更新"的 chat session 列表（用于元数据刷新）
        var touchedChatIds: Set<String> = []
        let now = Date().timeIntervalSince1970

        content.enumerateLines { line, _ in
            guard line.contains("[chatStreamService]") || line.contains("[ai-chat/v2]") else { return }

            // window 维度流状态（保留旧逻辑，作为兜底和兼容旧版 Trae）
            if self.isStartMarker(line) {
                currentState = true
                toggled = true
            } else if self.isEndMarker(line) {
                currentState = false
                toggled = true
            }

            // chat session 维度：元数据 + 流状态
            if let md = self.parseChatMetadata(line: line) {
                var cs = info.chatSessions[md.chatId] ?? ChatSessionInfo()
                cs.lastSeenAt = now
                if let t = md.title, !t.isEmpty { cs.title = t }
                if let w = md.workspacePath, !w.isEmpty { cs.workspacePath = w }
                if let c = md.createdAt { cs.createdAt = c }
                cs.seenInWindows.insert(logPath)
                info.chatSessions[md.chatId] = cs
                touchedChatIds.insert(md.chatId)
            }
            if let ev = self.parseChatStreamEvent(line: line) {
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
                touchedChatIds.insert(ev.chatId)
            }
        }

        let previousState = info.windowStates[logPath] ?? false
        info.windowStates[logPath] = currentState
        sessions[sessionId] = info

        // window 维度状态：作为兜底信号写入，但不再触发回调（chat session 维度已经覆盖动画触发）
        _ = previousState

        // chat session 维度回调（驱动状态条动画 + 菜单刷新）
        for (chatId, t) in chatTransitions {
            if t.nowRunning && !t.wasRunning {
                DispatchQueue.main.async { [weak self] in
                    self?.onChatSessionStart?(sessionId, chatId)
                }
            } else if !t.nowRunning && t.wasRunning {
                DispatchQueue.main.async { [weak self] in
                    self?.onChatSessionStop?(sessionId, chatId)
                }
            }
        }
        _ = touchedChatIds // 预留：将来想做"刚被 touch 的会话"提醒
    }

    // MARK: chat session 解析（业务层会话）

    /// 解析 Session fetched / Session updated / session_updated 等事件，
    /// 提取 chat_session_id / title / workspace_path / created_at。
    private func parseChatMetadata(line: String) -> (chatId: String, title: String?, workspacePath: String?, createdAt: Date?)? {
        // 仅关心 [ai-chat/v2] 行
        guard line.contains("[ai-chat/v2]") else { return nil }

        // Session fetched: ... {"chat_session_id":"...","title":"...","workspace_path":"...","created_at":"<ms>"}
        // Session updated: ... {"chat_session_id":"...","title":"..."}（仅更新 title）
        // event: session_updated ... "title":"..."
        guard let chatId = extractJSONString(line: line, key: "chat_session_id") else { return nil }
        // 兜底过滤：必须是 [a-f0-9]{20,} 形态，避免误把其他 JSON 字段当 chat id
        guard chatId.count >= 20, chatId.allSatisfy({ $0.isHexDigit }) else { return nil }

        let title = extractJSONString(line: line, key: "title")
        let workspace = extractJSONString(line: line, key: "workspace_path")
            ?? extractJSONString(line: line, key: "main_folder")
            ?? extractJSONString(line: line, key: "local_folder")
        var created: Date? = nil
        if let ms = extractJSONString(line: line, key: "created_at"), let v = TimeInterval(ms) {
            // Trae 的 created_at 是毫秒
            if v > 1_000_000_000_000 { created = Date(timeIntervalSince1970: v / 1000.0) }
            else if v > 1_000_000_000 { created = Date(timeIntervalSince1970: v) }
        }
        // 只有该行明确带 title/workspace/created_at 这几个字段之一，才视为元数据事件
        guard title != nil || workspace != nil || created != nil else { return nil }
        return (chatId, title, workspace, created)
    }

    /// chat session 维度的流事件：start / stop
    private func parseChatStreamEvent(line: String) -> (chatId: String, kind: StreamEventKind)? {
        guard line.contains("[ai-chat/v2]") else { return nil }
        guard let chatId = extractJSONString(line: line, key: "sessionId")
            ?? extractChatSessionIdFromTail(line: line)
        else { return nil }
        guard chatId.count >= 20, chatId.allSatisfy({ $0.isHexDigit }) else { return nil }

        if isStartMarker(line) {
            return (chatId, .start)
        }
        if isEndMarker(line) {
            return (chatId, .stop)
        }
        return nil
    }

    private enum StreamEventKind { case start, stop }

    /// 从形如 `... tailStatus: 6ab0cbed663253458ad9a836` 的尾部提取 chat session id
    /// （[NotificationPort] Stream started, subscribing to tailStatus: <id>）
    private func extractChatSessionIdFromTail(line: String) -> String? {
        guard let r = line.range(of: "tailStatus: ") else { return nil }
        let after = line[r.upperBound...]
        let token = after.prefix { $0.isHexDigit }
        return token.isEmpty ? nil : String(token)
    }

    /// 在日志行里非常宽松地找 `"key":"value"`：允许 value 含 \/、\" 等简单转义。
    /// 不做严格 JSON 解析，因为渲染端日志里 JSON 经常被嵌套 / 转义不全。
    private func extractJSONString(line: String, key: String) -> String? {
        let needle = "\"\(key)\":\""
        guard let r = line.range(of: needle) else { return nil }
        var out = ""
        let chars = Array(line)
        // r.upperBound 是 String.Index；用 line.distance 拿 Int offset，再当 chars 的下标
        var pos = line.distance(from: line.startIndex, to: r.upperBound)
        while pos < chars.count {
            let c = chars[pos]
            if c == "\\" && pos + 1 < chars.count {
                // 简单反转义：\" \\ \/ \n \t \uXXXX；其它原样保留
                let next = chars[pos + 1]
                switch next {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/":  out.append("/")
                case "n":  out.append("\n")
                case "t":  out.append("\t")
                case "u":
                    if pos + 5 < chars.count,
                       let code = UInt32(String(chars[pos+2...pos+5])) {
                        if let u = Unicode.Scalar(code) { out.append(Character(u)) }
                        pos += 6
                        continue
                    }
                default: out.append(next)
                }
                pos += 2
                continue
            }
            if c == "\"" { return out.isEmpty ? nil : out }
            out.append(c)
            pos += 1
        }
        return nil
    }

    /// 流式开始标记，兼容旧版 chatStreamService 和 Trae 3.3.90 ai-chat/v2。
    /// 注意：SessionStatusTrace 的 nextStatus 行是跨窗口广播（frontier.session_updated），
    /// 会被写入所有窗口的 renderer.log，不能作为本窗口流状态依据。
    private func isStartMarker(_ line: String) -> Bool {
        if line.contains("[chatStreamService]") {
            return line.contains("sendChatMessageStart") ||
                line.contains("beforeSteamingStart") ||
                line.contains("doRequestWithStream start") ||
                line.contains("streaming start") ||
                line.contains("calling chat API")
        }
        return line.contains("[ai-chat/v2] [StreamDomainService] Stream started") ||
            line.contains("[ai-chat/v2] [NotificationPort] Stream started")
    }

    /// 流式结束 / 中断 / 错误的日志标记。
    private func isEndMarker(_ line: String) -> Bool {
        line.contains("stream.onComplete") ||
        line.contains("stream.onError") ||
        line.contains("stream.onAbort") ||
        line.contains("stopType: Complete") ||
        line.contains("stopType: Error") ||
        line.contains("stopType: Abort") ||
        line.contains("stopType: Interrupted") ||
        line.contains("event=done") ||
        line.contains("[ai-chat/v2] [NotificationPort] Stream stopped") ||
        line.contains("[ai-chat/v2] [StreamDomainService] Stream finalized") ||
        line.contains("[ai-chat/v2] [stream-diagnostics][done] done finalized stream")
    }

    /// 看门狗：把"标记为运行中但 renderer.log 文件已长时间不再写入"的窗口强制复位为空闲，
    /// 兜底一切未识别结束路径导致的卡死。活跃判定用文件本身的修改时间（任何日志写入都算），
    /// 而不是 chatStreamService 心跳行——真实进行中的对话可能长时间不写这类行，用前者可避免误杀。
    /// 同时把该 window 从所有 chat session 的 runningWindows 里移除，让 chat session 维度同步复位。
    private func sweepStaleStreams() -> Bool {
        let now = Date()
        var changed = false
        let liveWindowPaths = Set(watchers.keys)

        for appSessionId in sessions.keys {
            guard var info = sessions[appSessionId] else { continue }
            var mutated = false
            var stopChatIds: [String] = []

            // 1) window 维度 reset
            for (path, running) in info.windowStates where running {
                let mtime = fileModificationDate(path)
                if now.timeIntervalSince(mtime) > Config.streamStallTimeout {
                    info.windowStates[path] = false
                    print("[trae-status-bar] Stalled window reset to idle: \(path)")
                    mutated = true
                }
            }

            // 2) chat session 维度：把 mtime 过期的 window 从 runningWindows 中移除
            for (chatId, var cs) in info.chatSessions {
                let before = cs.isRunning
                cs.runningWindows = cs.runningWindows.filter { wPath in
                    let m = fileModificationDate(wPath)
                    return now.timeIntervalSince(m) <= Config.streamStallTimeout
                }
                // 顺便 GC 已经不存在的 window（窗口被删/未挂载）
                let prunedSeen = cs.seenInWindows.intersection(liveWindowPaths)
                if prunedSeen != cs.seenInWindows { cs.seenInWindows = prunedSeen }
                let after = cs.isRunning
                if before != after {
                    info.chatSessions[chatId] = cs
                    if before && !after { stopChatIds.append(chatId) }
                    mutated = true
                } else if cs.runningWindows.isEmpty == false || cs.seenInWindows != cs.seenInWindows {
                    info.chatSessions[chatId] = cs
                }
            }

            if mutated { sessions[appSessionId] = info; changed = true }

            // 3) 回调：chat session 维度（menu 唯一关心的状态）
            for chatId in stopChatIds {
                DispatchQueue.main.async { [weak self] in
                    self?.onChatSessionStop?(appSessionId, chatId)
                }
            }
        }
        return changed
    }

    /// 文件最后修改时间；文件不存在或读取失败返回 distantPast（视为长时间未活跃）
    private func fileModificationDate(_ path: String) -> Date {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let d = attrs[.modificationDate] as? Date else {
            return Date.distantPast
        }
        return d
    }

    // MARK: 存活判定

    /// 会话目录存在窗口目录，且其内容在存活阈值内有过写入
    private func isSessionLive(_ sessionPath: String) -> Bool {
        let now = Date()
        func recent(_ date: Date?) -> Bool {
            guard let date else { return false }
            return now.timeIntervalSince(date) < Config.sessionStaleThreshold
        }

        // 会话目录顶层文件（main.log 等，Trae 运行时会持续写入）
        if let items = try? FileManager.default.contentsOfDirectory(atPath: sessionPath) {
            for item in items {
                let p = "\(sessionPath)/\(item)"
                if let attrs = try? FileManager.default.attributesOfItem(atPath: p),
                   let d = attrs[.modificationDate] as? Date, recent(d) {
                    return true
                }
            }
        }
        // 各窗口 renderer.log
        if let windows = try? FileManager.default.contentsOfDirectory(atPath: sessionPath).filter({ $0.hasPrefix("window") }) {
            for w in windows {
                let p = "\(sessionPath)/\(w)/renderer.log"
                if let attrs = try? FileManager.default.attributesOfItem(atPath: p),
                   let d = attrs[.modificationDate] as? Date, recent(d) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: 目录监听

    private func watchBaseDir() {
        guard let handle = FileHandle(forReadingAtPath: logsBase) else { return }
        let fd = handle.fileDescriptor

        let dispatchSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .main
        )
        dispatchSource.setEventHandler { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self?.scanAndWatch()
            }
        }
        dispatchSource.resume()
        self.baseDirWatcher = dispatchSource
    }

    private static let sessionPattern = try! NSRegularExpression(pattern: #"^\d{8}T\d{6}$"#)

    /// 从运行中的 Trae 进程命令行提取存活会话 ID。解析失败或无结果时返回 nil，
    /// 由调用方回退到 mtime 启发式（isSessionLive）。
    private static func liveSessionIdsFromProcesses() -> Set<String>? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return nil
        }
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

    private static func hasWindows(in sessionPath: String) -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: sessionPath) else { return false }
        return items.contains { $0.hasPrefix("window") }
    }

    deinit {
        baseDirWatcher?.cancel()
        rescanTimer?.invalidate()
    }
}

// MARK: - 单个聚合状态栏条目
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var monitor: TraeLogMonitor?
    private var isAnimating = false
    private var timer: Timer?
    private var frameIndex = 0
    private let frames = ["◐", "◓", "◑", "◒"]

    private var activeCount: Int { monitor?.activeSessionCount ?? 0 }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        statusItem.button?.toolTip = "Trae 会话状态"
        statusItem.menu = NSMenu()
        setTitle("⬤")
        rebuildMenu()

        monitor = TraeLogMonitor(logsBase: Config.logsBase)
        monitor?.onSessionAdded = { [weak self] _ in
            self?.rebuildMenu()
        }
        monitor?.onSessionRemoved = { [weak self] _ in
            self?.rebuildMenu()
        }
        monitor?.onChatSessionStart = { [weak self] _, _ in
            self?.syncState()
        }
        monitor?.onChatSessionStop = { [weak self] _, _ in
            self?.syncState()
        }
        monitor?.start()

        // 周期性刷新菜单（chat session 的 title / workspace 可能在启动后才写出来）
        Timer.scheduledTimer(withTimeInterval: Config.rescanInterval, repeats: true) { [weak self] _ in
            self?.rebuildMenu()
        }
    }

    /// 根据当前进行中的会话个数刷新动画与标题
    private func syncState() {
        let n = activeCount
        if n > 0 {
            startAnimation()
            updateTitle() // 用当前计数立即刷新标题
        } else {
            stopAnimation()
        }
        rebuildMenu()
    }

    private func startAnimation() {
        guard !isAnimating else { return }
        isAnimating = true
        frameIndex = 0
        setTitle(frames[0] + "\(activeCount)")
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.isAnimating else { return }
            self.frameIndex = (self.frameIndex + 1) % self.frames.count
            self.setTitle(self.frames[self.frameIndex] + "\(self.activeCount)")
        }
        print("[trae-status-bar] Animation started (active sessions: \(activeCount))")
    }

    private func stopAnimation() {
        guard isAnimating else { return }
        isAnimating = false
        timer?.invalidate()
        timer = nil
        setTitle("⬤")
        print("[trae-status-bar] Animation stopped")
    }

    private func updateTitle() {
        if isAnimating {
            setTitle(frames[frameIndex] + "\(activeCount)")
        } else {
            setTitle("⬤")
        }
    }

    private func setTitle(_ text: String) {
        statusItem.button?.title = text
    }

    /// 重建菜单：聚合标题 + 每个 chat session（业务层对话）的状态。
    /// 平铺，不再嵌套 window 子菜单。每个 item 展示：
    ///   <状态>  <工作区短名> · <标题>   [HH:MM 创建时间]
    /// 名字缺失时降级：title → workspace basename → 短 ID。
    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let title = activeCount > 0 ? "Trae: \(activeCount) 个会话进行中" : "Trae: 空闲"
        menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        let all = monitor?.allChatSessions() ?? []
        if all.isEmpty {
            menu.addItem(NSMenuItem(title: "（暂无存活会话）", action: nil, keyEquivalent: ""))
        } else {
            // 按 appSessionId 分组显示（保留 Trae 应用启动作为分组 header），不再展开 window submenu
            var currentAppId: String? = nil
            let df = DateFormatter()
            df.dateFormat = "HH:mm"
            for entry in all {
                if entry.appSessionId != currentAppId {
                    currentAppId = entry.appSessionId
                    let header = NSMenuItem(title: formatAppSessionLabel(entry.appSessionId),
                                             action: nil, keyEquivalent: "")
                    header.isEnabled = false
                    menu.addItem(header)
                }
                let line = formatChatSessionLine(chatId: entry.chatId, info: entry.info, df: df)
                menu.addItem(NSMenuItem(title: line, action: nil, keyEquivalent: ""))
            }
        }

        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit trae-status-bar", action: #selector(quitAll), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// 应用启动目录名（如 20260920T121608） → "Trae · 2026-09-20 12:16:08"
    private func formatAppSessionLabel(_ appId: String) -> String {
        guard appId.count >= 15,
              appId.hasPrefix("20") else { return "Trae · \(appId)" }
        // 20260920T121608
        let yyyy = String(appId.prefix(4))
        let mm = String(appId.dropFirst(4).prefix(2))
        let dd = String(appId.dropFirst(6).prefix(2))
        let HH = String(appId.dropFirst(9).prefix(2))
        let MM = String(appId.dropFirst(11).prefix(2))
        let SS = String(appId.dropFirst(13).prefix(2))
        return "Trae · \(yyyy)-\(mm)-\(dd) \(HH):\(MM):\(SS)"
    }

    /// 单个 chat session 菜单行：
    ///   ▶  mp-dialer · 使用 grill-me master_huawei_kms    [14:17]
    ///   ○  Master Refactor Predict Call Branch            [14:18]
    private func formatChatSessionLine(chatId: String, info: TraeLogMonitor.ChatSessionInfo, df: DateFormatter) -> String {
        let marker = info.isRunning ? "▶" : "○"
        let workspace = info.workspaceShort ?? ""
        let display = info.displayName
        let shortId = String(chatId.suffix(6))
        let time: String
        if let d = info.createdAt {
            time = df.string(from: d)
        } else {
            time = "·" + shortId
        }
        let name: String
        if !workspace.isEmpty && workspace != display {
            name = "\(workspace) · \(display)"
        } else if !workspace.isEmpty {
            name = workspace
        } else if !info.title.isEmpty {
            name = display
        } else {
            name = "会话 ·" + shortId
        }
        return "\(marker)  \(name)  [\(time)]"
    }

    @objc func quitAll() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Entry point
setvbuf(stdout, nil, _IOLBF, 0) // 行缓冲，保证重定向到文件时日志实时可见
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
