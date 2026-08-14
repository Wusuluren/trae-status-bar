import AppKit
import Foundation

// MARK: - 配置
enum Config {
    /// 会话目录被视为"存活"的最大静默时间（该会话所有文件无任何日志写入则视为已关闭）
    static let sessionStaleThreshold: TimeInterval = 6 * 3600
    /// 无日志活动后停止动画的安全超时
    static let animationTimeout: TimeInterval = 90
    /// 目录重扫间隔（秒）
    static let rescanInterval: TimeInterval = 5
    /// 新挂载 watcher 时回读文件尾部的字节数，用于初始化窗口的流状态
    static let tailBytes: Int = 20_000
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

    init(logsBase: String) {
        self.logsBase = logsBase
    }

    func start() {
        scanAndWatch()
        watchBaseDir()
        rescanTimer = Timer.scheduledTimer(withTimeInterval: Config.rescanInterval, repeats: true) { [weak self] _ in
            self?.scanAndWatch()
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
        guard var info = sessions[sessionId] else { return }
        let sessionPath = info.path
        guard let windows = try? FileManager.default.contentsOfDirectory(atPath: sessionPath)
            .filter({ $0.hasPrefix("window") }) else { return }

        let watchedPaths = Set(info.windowStates.keys)
        var currentPaths = Set<String>()

        for window in windows {
            let logPath = "\(sessionPath)/\(window)/renderer.log"
            guard FileManager.default.fileExists(atPath: logPath) else { continue }
            currentPaths.insert(logPath)

            if watchedPaths.contains(logPath) { continue }

            info.windowStates[logPath] = false
            let w = FileWatcher(path: logPath)
            w.onNewLines = { [weak self] content in
                self?.parseLines(content, sessionId: sessionId, logPath: logPath)
            }
            w.start()
            watchers[logPath] = w
            print("[trae-status-bar] Watching: \(logPath)")
            // 回读尾部，初始化窗口状态，避免漏掉已开始的流
            w.readTail(Config.tailBytes)
        }

        // 移除已删除的窗口
        let removedPaths = watchedPaths.subtracting(currentPaths)
        if !removedPaths.isEmpty {
            for path in removedPaths {
                info.windowStates.removeValue(forKey: path)
                watchers.removeValue(forKey: path)
            }
            print("[trae-status-bar] Removed windows: \(removedPaths)")
        }

        sessions[sessionId] = info
    }

    // MARK: 日志解析

    private func parseLines(_ content: String, sessionId: String, logPath: String) {
        guard var info = sessions[sessionId] else { return }
        var currentState = info.windowStates[logPath] ?? false

        content.enumerateLines { line, _ in
            // Only match actual stream events, not tool execution logs
            if line.contains("[chatStreamService]") {
                if line.contains("sendChatMessageStart") || line.contains("beforeSteamingStart") || line.contains("doRequestWithStream start") || line.contains("streaming start") || line.contains("calling chat API") {
                    currentState = true
                } else if line.contains("stream.onComplete") || line.contains("stopType: Complete") || line.contains("stopType: Error") || line.contains("event=done") {
                    currentState = false
                }
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
        } else if currentState && previousState {
            // 持续运行——刷新安全计时器
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

// MARK: - 单个会话的状态栏条目
class SessionStatusItem {
    let sessionId: String
    let statusItem: NSStatusItem
    private let menu: NSMenu
    private let titleItem: NSMenuItem
    private var windowItems: [NSMenuItem] = []
    private var isAnimating = false
    private var timer: Timer?
    private var frameIndex = 0
    private var lastActivity = Date()
    private let frames = ["◐", "◓", "◑", "◒"]

    /// 20260812T145615 -> 14:56
    static func shortLabel(for sessionId: String) -> String {
        let chars = Array(sessionId)
        guard chars.count >= 13 else { return sessionId }
        return "\(chars[9])\(chars[10]):\(chars[11])\(chars[12])"
    }

    init(sessionId: String) {
        self.sessionId = sessionId
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        statusItem.button?.toolTip = "Trae 会话 \(sessionId)"

        menu = NSMenu()
        titleItem = NSMenuItem(title: "Trae 会话 \(sessionId): 空闲", action: nil, keyEquivalent: "")
        menu.addItem(titleItem)
        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit trae-status-bar", action: #selector(AppDelegate.quitAll), keyEquivalent: "q")
        quit.target = NSApp.delegate
        menu.addItem(quit)
        statusItem.menu = menu

        setTitle("⬤")
    }

    private func setTitle(_ text: String) {
        statusItem.button?.title = "\(Self.shortLabel(for: sessionId)) \(text)"
    }

    func startAnimation() {
        guard !isAnimating else { return }
        isAnimating = true
        titleItem.title = "Trae 会话 \(sessionId): 运行中"
        frameIndex = 0
        setTitle(frames[0])
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.frameIndex = (self.frameIndex + 1) % self.frames.count
            self.setTitle(self.frames[self.frameIndex])
        }
        print("[trae-status-bar] Animation started: \(sessionId)")
    }

    func stopAnimation() {
        guard isAnimating else { return }
        isAnimating = false
        timer?.invalidate()
        timer = nil
        setTitle("⬤")
        titleItem.title = "Trae 会话 \(sessionId): 空闲"
        print("[trae-status-bar] Animation stopped: \(sessionId)")
    }

    func noteActivity() {
        lastActivity = Date()
    }

    /// 安全超时检查：该会话持续动画但无任何日志活动
    func checkTimeout() {
        guard isAnimating, Date().timeIntervalSince(lastActivity) > Config.animationTimeout else { return }
        print("[trae-status-bar] Safety timeout: session \(sessionId)")
        stopAnimation()
    }

    /// 刷新菜单中的窗口状态列表
    func updateWindows(_ windows: [(name: String, running: Bool)]) {
        for item in windowItems {
            menu.removeItem(item)
        }
        windowItems.removeAll()

        var insertIndex = 2 // 0=标题, 1=分隔线, 之后是窗口列表, 最后是 Quit
        for w in windows {
            let item = NSMenuItem(title: "\(w.name): \(w.running ? "运行中" : "空闲")", action: nil, keyEquivalent: "")
            menu.insertItem(item, at: insertIndex)
            windowItems.append(item)
            insertIndex += 1
        }
    }

    deinit {
        timer?.invalidate()
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: TraeLogMonitor?
    private var sessionItems: [String: SessionStatusItem] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor = TraeLogMonitor(logsBase: Config.logsBase)

        monitor?.onSessionAdded = { [weak self] sessionId in
            self?.addSessionItem(sessionId)
        }
        monitor?.onSessionRemoved = { [weak self] sessionId in
            self?.removeSessionItem(sessionId)
        }
        monitor?.onSessionStart = { [weak self] sessionId in
            guard let self, let item = self.sessionItems[sessionId] else { return }
            item.noteActivity()
            item.startAnimation()
            item.updateWindows(self.monitor?.windowStates(for: sessionId) ?? [])
        }
        monitor?.onSessionStop = { [weak self] sessionId in
            guard let self, let item = self.sessionItems[sessionId] else { return }
            item.stopAnimation()
            item.updateWindows(self.monitor?.windowStates(for: sessionId) ?? [])
        }
        monitor?.onSessionActivity = { [weak self] sessionId in
            self?.sessionItems[sessionId]?.noteActivity()
        }
        monitor?.start()

        // 安全超时轮询：每个动画中的会话若无日志活动则停止
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            for item in self.sessionItems.values {
                item.checkTimeout()
            }
        }

        // 周期性刷新各会话菜单中的窗口状态
        Timer.scheduledTimer(withTimeInterval: Config.rescanInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            for (id, item) in self.sessionItems {
                item.updateWindows(self.monitor?.windowStates(for: id) ?? [])
            }
        }
    }

    private func addSessionItem(_ sessionId: String) {
        guard sessionItems[sessionId] == nil else { return }
        let item = SessionStatusItem(sessionId: sessionId)
        sessionItems[sessionId] = item
        item.updateWindows(monitor?.windowStates(for: sessionId) ?? [])
        print("[trae-status-bar] Status item added: \(sessionId)")
    }

    private func removeSessionItem(_ sessionId: String) {
        guard sessionItems.removeValue(forKey: sessionId) != nil else { return }
        print("[trae-status-bar] Status item removed: \(sessionId)")
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
