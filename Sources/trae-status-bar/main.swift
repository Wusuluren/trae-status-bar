import AppKit
import Foundation

// MARK: - 单文件监听器
class FileWatcher {
    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    let path: String
    var onNewLines: ((String) -> Void)?

    init(path: String) {
        self.path = path
    }

    func start() {
        guard FileManager.default.fileExists(atPath: path) else {
            print("[trae-status-bar] File not found: \(path)")
            return
        }
        guard let handle = FileHandle(forReadingAtPath: path) else {
            print("[trae-status-bar] Cannot open file: \(path)")
            return
        }
        handle.seekToEndOfFile()
        self.fileHandle = handle

        let fd = handle.fileDescriptor
        let dispatchSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.extend, .write],
            queue: .main
        )
        dispatchSource.setEventHandler { [weak self] in
            self?.readNewLines()
        }
        dispatchSource.resume()
        self.source = dispatchSource
    }

    private func readNewLines() {
        guard let handle = fileHandle else { return }
        let data = handle.readDataToEndOfFile()
        guard let content = String(data: data, encoding: .utf8) else { return }
        onNewLines?(content)
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
    private var sessionDirWatcher: DispatchSourceFileSystemObject?
    var onAnyStart: (() -> Void)?
    var onAllStop: (() -> Void)?
    var activeCount: Int { streamStates.values.filter { $0 }.count }

    init(logsBase: String) {
        self.logsBase = logsBase
    }

    func start() {
        watchSession()
        watchLogsDirectory()
    }

    // MARK: - 监听当前 session 下所有 window 的 renderer.log
    private func watchSession() {
        // 停止旧的 watchers
        watchers.forEach { $0.onNewLines = nil }
        watchers.removeAll()

        guard let sessionDir = findLatestSession() else {
            print("[trae-status-bar] No renderer.log found")
            return
        }

        let sessionPath = "\(logsBase)/\(sessionDir)"
        guard let windows = try? FileManager.default.contentsOfDirectory(atPath: sessionPath)
            .filter({ $0.hasPrefix("window") }) else { return }

        for window in windows {
            let logPath = "\(sessionPath)/\(window)/renderer.log"
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
    }

    private func parseLines(_ content: String, from path: String) {
        var started = false
        var stopped = false

        // debug: 每次读到的内容写入 /tmp 文件
        if let debugHandle = FileHandle(forWritingAtPath: "/tmp/trae_debug.log") {
            debugHandle.seekToEndOfFile()
            let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            let preview = String(content.prefix(500))
            debugHandle.write("[\(ts)] read \(content.count) bytes from \(path)\n".data(using: .utf8)!)
            debugHandle.write("[\(ts)] preview: \(preview)\n---\n".data(using: .utf8)!)
            debugHandle.closeFile()
        } else {
            // try create
            try? content.write(toFile: "/tmp/trae_debug.log", atomically: false, encoding: .utf8)
        }

        content.enumerateLines { line, _ in
            if line.contains("doRequestWithStream start") || line.contains("streaming start") || line.contains("calling chat API") {
                started = true
            } else if line.contains("event=done") || line.contains("stream.onComplete") || line.contains("stopType: Complete") || line.contains("stopType: Error") {
                stopped = true
            }
        }

        if started {
            streamStates[path] = true
            DispatchQueue.main.async { [weak self] in
                self?.onAnyStart?()
            }
        }
        if stopped {
            streamStates[path] = false
            // 所有窗口都 idle 了才触发 onAllStop
            let anyRunning = streamStates.values.contains(true)
            if !anyRunning {
                DispatchQueue.main.async { [weak self] in
                    self?.onAllStop?()
                }
            }
        }
    }

    // MARK: - 监控 logs 目录，新 session 出现时自动切换
    private func watchLogsDirectory() {
        guard let handle = FileHandle(forReadingAtPath: logsBase) else { return }
        let fd = handle.fileDescriptor

        let dispatchSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        dispatchSource.setEventHandler { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self?.watchSession()
            }
        }
        dispatchSource.resume()
        self.sessionDirWatcher = dispatchSource
    }

    private func findLatestSession() -> String? {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: logsBase) else { return nil }
        let sessions = contents.filter { $0.hasPrefix("2026") || $0.hasPrefix("2025") }.sorted(by: >)
        for session in sessions {
            let testPath = "\(logsBase)/\(session)/window1/renderer.log"
            if FileManager.default.fileExists(atPath: testPath) {
                return session
            }
        }
        return nil
    }

    deinit {
        sessionDirWatcher?.cancel()
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var isAnimating = false
    private var timer: Timer?
    private var monitor: TraeLogMonitor?
    private var frameIndex = 0
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
            self?.startAnimation()
        }
        monitor?.onAllStop = { [weak self] in
            self?.stopAnimation()
        }
        monitor?.start()
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