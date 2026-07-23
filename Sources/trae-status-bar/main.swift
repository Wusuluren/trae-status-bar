import AppKit
import Foundation

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

// MARK: - 多窗口日志监控器
class TraeLogMonitor {
    private var watchers: [FileWatcher] = []
    private var streamStates: [String: Bool] = [:] // path: isRunning
    private let logsBase: String
    private var currentSessionPath: String?
    private var baseDirWatcher: DispatchSourceFileSystemObject?
    private var sessionDirWatcher: DispatchSourceFileSystemObject?
    private var rescanTimer: Timer?
    private var pendingStopTimer: Timer?
    private let stopGracePeriod: TimeInterval = 3.0
    private var lastActivityTime: Date = Date()
    private var safetyTimer: Timer?
    private let safetyTimeout: TimeInterval = 30
    var onAnyStart: (() -> Void)?
    var onAllStop: (() -> Void)?
    var activeCount: Int { streamStates.values.filter { $0 }.count }

    init(logsBase: String) {
        self.logsBase = logsBase
    }

    func start() {
        scanAndWatch()
        watchBaseDir()
        rescanTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.scanAndWatch()
        }
    }

    private func scanAndWatch() {
        guard let sessionDir = findLatestSession() else {
            print("[trae-status-bar] No session found")
            return
        }
        let sessionPath = "\(logsBase)/\(sessionDir)"

        if sessionPath != currentSessionPath {
            print("[trae-status-bar] Session changed: \(sessionDir)")
            currentSessionPath = sessionPath
            watchers.forEach { $0.onNewLines = nil }
            watchers.removeAll()
            streamStates.removeAll()
            watchSessionDir(sessionPath)
        }

        refreshWindows(in: sessionPath)
    }

    private func refreshWindows(in sessionPath: String) {
        guard let windows = try? FileManager.default.contentsOfDirectory(atPath: sessionPath)
            .filter({ $0.hasPrefix("window") }) else { return }

        let watchedPaths = Set(streamStates.keys)
        var currentPaths = Set<String>()

        for window in windows {
            let logPath = "\(sessionPath)/\(window)/renderer.log"
            currentPaths.insert(logPath)

            if watchedPaths.contains(logPath) { continue }
            guard FileManager.default.fileExists(atPath: logPath) else { continue }

            streamStates[logPath] = false
            let w = FileWatcher(path: logPath)
            w.onNewLines = { [weak self] content in
                self?.parseLines(content, from: logPath)
            }
            w.start()
            watchers.append(w)
            print("[trae-status-bar] Watching: \(logPath)")
        }

        let removed = watchedPaths.subtracting(currentPaths)
        if !removed.isEmpty {
            for path in removed {
                streamStates.removeValue(forKey: path)
            }
            watchers = watchers.filter { streamStates.keys.contains($0.path) }
            print("[trae-status-bar] Removed: \(removed)")
        }
    }

    private func parseLines(_ content: String, from path: String) {
        var currentState = streamStates[path] ?? false
        
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
        
        let previousState = streamStates[path] ?? false
        streamStates[path] = currentState
        
        if currentState && !previousState {
            DispatchQueue.main.async { [weak self] in
                self?.onAnyStart?()
            }
        } else if !currentState && previousState {
            let anyRunning = streamStates.values.contains(true)
            if !anyRunning {
                DispatchQueue.main.async { [weak self] in
                    self?.onAllStop?()
                }
            }
        }
    }

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

    private func watchSessionDir(_ path: String) {
        sessionDirWatcher?.cancel()
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        let fd = handle.fileDescriptor

        let dispatchSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .main
        )
        dispatchSource.setEventHandler { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let self = self, let sp = self.currentSessionPath else { return }
                self.refreshWindows(in: sp)
            }
        }
        dispatchSource.resume()
        self.sessionDirWatcher = dispatchSource
        print("[trae-status-bar] Watching session dir: \(path)")
    }

    private static let sessionPattern = try! NSRegularExpression(pattern: #"^\d{8}T\d{6}$"#)

    private func findLatestSession() -> String? {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: logsBase) else { return nil }
        let sessions = contents.filter {
            Self.sessionPattern.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
        }.sorted(by: >)
        for session in sessions {
            let sessionPath = "\(logsBase)/\(session)"
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: sessionPath) else { continue }
            let hasWindow = items.contains { $0.hasPrefix("window") }
            if hasWindow { return session }
        }
        return nil
    }

    deinit {
        baseDirWatcher?.cancel()
        sessionDirWatcher?.cancel()
        rescanTimer?.invalidate()
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var isAnimating = false
    private var timer: Timer?
    private var monitor: TraeLogMonitor?
    private var frameIndex = 0
    private var lastActivityTime = Date()
    private let frames = ["◐", "◓", "◑", "◒"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⬤"
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)

        let menu = NSMenu()
        let titleItem = NSMenuItem(title: "Trae: Idle", action: nil, keyEquivalent: "")
        menu.addItem(titleItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu

        monitor = TraeLogMonitor(logsBase: "/Users/wav/Library/Application Support/Trae CN/logs")
        monitor?.onAnyStart = { [weak self] in
            self?.lastActivityTime = Date()
            self?.startAnimation()
        }
        monitor?.onAllStop = { [weak self] in
            self?.stopAnimation()
        }
        monitor?.start()

        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isAnimating else { return }
            if Date().timeIntervalSince(self.lastActivityTime) > 60 {
                print("[trae-status-bar] Safety timeout: stopping animation after 60s inactivity")
                self.stopAnimation()
            }
        }
    }

    private func startAnimation() {
        guard !isAnimating else { return }
        isAnimating = true
        updateMenuTitle("Trae: Running")

        frameIndex = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.frameIndex = (self.frameIndex + 1) % self.frames.count
            self.statusItem.button?.title = self.frames[self.frameIndex]
        }

        print("[trae-status-bar] Animation started (\(monitor?.activeCount ?? 1) windows active)")
    }

    private func stopAnimation() {
        guard isAnimating else { return }
        isAnimating = false
        timer?.invalidate()
        timer = nil
        statusItem.button?.title = "⬤"
        updateMenuTitle("Trae: Idle")
        print("[trae-status-bar] Animation stopped")
    }

    private func updateMenuTitle(_ title: String) {
        if let menu = statusItem.menu, let item = menu.items.first {
            item.title = title
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Entry point
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()