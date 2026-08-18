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
    struct SessionInfo {
        var path: String
        var windowStates: [String: Bool] = [:] // windowLogPath -> isRunning
    }

    private var sessions: [String: SessionInfo] = [:] // sessionId -> info
    private var watchers: [String: FileWatcher] = [:] // windowLogPath -> watcher
    private let logsBase: String
    private var baseDirWatcher: DispatchSourceFileSystemObject?
    private var rescanTimer: Timer?

    // 会话级回调（主线程）
    var onSessionAdded: ((String) -> Void)?    // sessionId
    var onSessionRemoved: ((String) -> Void)?  // sessionId
    var onSessionStart: ((String) -> Void)?    // sessionId
    var onSessionStop: ((String) -> Void)?     // sessionId
    var onSessionActivity: ((String) -> Void)? // sessionId

    var sessionIds: [String] { sessions.keys.sorted() }

    /// 某会话各窗口的 (窗口名, 是否运行中)，用于菜单展示
    func windowStates(for sessionId: String) -> [(name: String, running: Bool)] {
        guard let info = sessions[sessionId] else { return [] }
        return info.windowStates
            .map { (name: URL(fileURLWithPath: $0.key).deletingLastPathComponent().lastPathComponent, running: $0.value) }
            .sorted { $0.name < $1.name }
    }

    /// 该会话当前是否有窗口在流式输出
    func sessionRunning(_ sessionId: String) -> Bool {
        guard let info = sessions[sessionId] else { return false }
        return info.windowStates.values.contains(true)
    }

    /// 所有会话中进行中的会话个数
    var activeSessionCount: Int {
        sessions.values.reduce(0) { count, info in
            info.windowStates.values.contains(true) ? count + 1 : count
        }
    }

    init(logsBase: String) {
        self.logsBase = logsBase
    }

    func start() {
        scanAndWatch()
        watchBaseDir()
        rescanTimer = Timer.scheduledTimer(withTimeInterval: Config.rescanInterval, repeats: true) { [weak self] _ in
            self?.scanAndWatch()
            // 看门狗：把僵死的 running 窗口复位为空闲（5 秒一次，远小于阈值）
            _ = self?.sweepStaleStreams()
        }
    }

    // MARK: 扫描

    private func scanAndWatch() {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: logsBase) else { return }

        let live = contents
            .filter(Self.isSessionDir)
            .filter { Self.hasWindows(in: "\(logsBase)/\($0)") }
            .filter { isSessionLive("\(logsBase)/\($0)") }
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

        content.enumerateLines { line, _ in
            guard line.contains("[chatStreamService]") else { return }

            if line.contains("sendChatMessageStart") || line.contains("beforeSteamingStart") || line.contains("doRequestWithStream start") || line.contains("streaming start") || line.contains("calling chat API") {
                currentState = true
                toggled = true
            } else if self.isEndMarker(line) {
                currentState = false
                toggled = true
            }
        }

        let previousState = info.windowStates[logPath] ?? false
        info.windowStates[logPath] = currentState
        sessions[sessionId] = info

        if currentState && !previousState {
            // State: idle -> running
            DispatchQueue.main.async { [weak self] in
                self?.onSessionStart?(sessionId)
            }
        } else if currentState && previousState && toggled {
            // State: running -> running（有新一行活动，但不涉及开始/结束转换）
            DispatchQueue.main.async { [weak self] in
                self?.onSessionActivity?(sessionId)
            }
        } else if !currentState && previousState {
            let anyRunning = info.windowStates.values.contains(true)
            if !anyRunning {
                DispatchQueue.main.async { [weak self] in
                    self?.onSessionStop?(sessionId)
                }
            }
        }
    }

    /// 流式结束 / 中断 / 错误的日志标记
    private func isEndMarker(_ line: String) -> Bool {
        line.contains("stream.onComplete") ||
        line.contains("stream.onError") ||
        line.contains("stream.onAbort") ||
        line.contains("stopType: Complete") ||
        line.contains("stopType: Error") ||
        line.contains("stopType: Abort") ||
        line.contains("stopType: Interrupted") ||
        line.contains("event=done")
    }

    /// 看门狗：把"标记为运行中但 renderer.log 文件已长时间不再写入"的窗口强制复位为空闲，
    /// 兜底一切未识别结束路径导致的卡死。活跃判定用文件本身的修改时间（任何日志写入都算），
    /// 而不是 chatStreamService 心跳行——真实进行中的对话可能长时间不写这类行，用前者可避免误杀。
    private func sweepStaleStreams() -> Bool {
        let now = Date()
        var resetSessions = Set<String>()
        var changed = false

        for sessionId in sessions.keys {
            guard var info = sessions[sessionId] else { continue }
            var mutated = false
            for (path, running) in info.windowStates where running {
                let mtime = fileModificationDate(path)
                if now.timeIntervalSince(mtime) > Config.streamStallTimeout {
                    info.windowStates[path] = false
                    print("[trae-status-bar] Stalled window reset to idle: \(path)")
                    mutated = true
                }
            }
            if mutated {
                changed = true
                sessions[sessionId] = info
                if !info.windowStates.values.contains(true) {
                    resetSessions.insert(sessionId)
                }
            }
        }

        for sessionId in resetSessions {
            DispatchQueue.main.async { [weak self] in
                self?.onSessionStop?(sessionId)
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
            self?.syncState()
        }
        monitor?.onSessionRemoved = { [weak self] _ in
            self?.syncState()
        }
        monitor?.onSessionStart = { [weak self] _ in
            self?.syncState()
        }
        monitor?.onSessionStop = { [weak self] _ in
            self?.syncState()
        }
        monitor?.start()

        // 周期性刷新菜单中的窗口状态
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

    /// 重建菜单：聚合标题 + 每个会话的状态（含其窗口列表子菜单）
    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let title = activeCount > 0 ? "Trae: \(activeCount) 个会话进行中" : "Trae: 空闲"
        let titleItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.addItem(titleItem)
        menu.addItem(NSMenuItem.separator())

        let ids = monitor?.sessionIds ?? []
        if ids.isEmpty {
            menu.addItem(NSMenuItem(title: "（暂无存活会话）", action: nil, keyEquivalent: ""))
        } else {
            for sessionId in ids {
                let running = monitor?.sessionRunning(sessionId) ?? false
                let windows = monitor?.windowStates(for: sessionId) ?? []
                let item = NSMenuItem(title: "会话 \(sessionId) — \(running ? "运行中" : "空闲")",
                                      action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for w in windows.isEmpty ? [(name: "（无窗口）", running: false)] : windows {
                    sub.addItem(NSMenuItem(title: "\(w.name): \(w.running ? "运行中" : "空闲")",
                                           action: nil, keyEquivalent: ""))
                }
                item.submenu = sub
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit trae-status-bar", action: #selector(quitAll), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
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
