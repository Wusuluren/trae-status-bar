import AppKit

/// 菜单栏聚合状态指示器：图标随进行中的 chat session 个数旋转，菜单平铺展示每个会话。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let source: LogSource
    private var statusItem: NSStatusItem!
    private var monitor: LogMonitor?
    private var isAnimating = false
    private var timer: Timer?
    private var frameIndex = 0
    private let frames = ["◐", "◓", "◑", "◒"]

    private var activeCount: Int { monitor?.activeSessionCount ?? 0 }
    private var name: String { source.displayName }

    init(source: LogSource) {
        self.source = source
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        statusItem.button?.toolTip = "\(name) 会话状态"
        statusItem.menu = NSMenu()
        setTitle("⬤")
        rebuildMenu()

        let monitor = LogMonitor(source: source)
        monitor.onSessionAdded = { [weak self] _ in self?.rebuildMenu() }
        monitor.onSessionRemoved = { [weak self] _ in self?.rebuildMenu() }
        monitor.onChatSessionStart = { [weak self] _, _ in self?.syncState() }
        monitor.onChatSessionStop = { [weak self] _, _ in self?.syncState() }
        monitor.start()
        self.monitor = monitor

        // 周期性刷新菜单（title / workspace 可能在会话启动后才写出来）
        Timer.scheduledTimer(withTimeInterval: Config.rescanInterval, repeats: true) { [weak self] _ in
            self?.rebuildMenu()
        }
    }

    private func syncState() {
        if activeCount > 0 {
            startAnimation()
            updateTitle()
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
        print("[qoder-status-bar] Animation started (active sessions: \(activeCount))")
    }

    private func stopAnimation() {
        guard isAnimating else { return }
        isAnimating = false
        timer?.invalidate()
        timer = nil
        setTitle("⬤")
        print("[qoder-status-bar] Animation stopped")
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

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let title = activeCount > 0 ? "\(name): \(activeCount) 个会话进行中" : "\(name): 空闲"
        menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        let all = monitor?.allChatSessions() ?? []
        if all.isEmpty {
            menu.addItem(NSMenuItem(title: "（暂无存活会话）", action: nil, keyEquivalent: ""))
        } else {
            var currentId: String? = nil
            let df = DateFormatter()
            df.dateFormat = "HH:mm"
            for entry in all {
                if entry.sessionId != currentId {
                    currentId = entry.sessionId
                    let header = NSMenuItem(title: formatAppSessionLabel(entry.sessionId),
                                            action: nil, keyEquivalent: "")
                    header.isEnabled = false
                    menu.addItem(header)
                }
                let line = formatChatSessionLine(chatId: entry.chatId, info: entry.info, df: df)
                menu.addItem(NSMenuItem(title: line, action: nil, keyEquivalent: ""))
            }
        }

        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit qoder-status-bar", action: #selector(quitAll), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// 会话目录末段（如 20260929T161645）→ "Qoder · 2026-09-29 16:16:45"
    private func formatAppSessionLabel(_ sessionPath: String) -> String {
        let appId = (sessionPath as NSString).lastPathComponent
        guard appId.count >= 15, appId.hasPrefix("20") else { return "\(name) · \(appId)" }
        let yyyy = String(appId.prefix(4))
        let mm = String(appId.dropFirst(4).prefix(2))
        let dd = String(appId.dropFirst(6).prefix(2))
        let HH = String(appId.dropFirst(9).prefix(2))
        let MM = String(appId.dropFirst(11).prefix(2))
        let SS = String(appId.dropFirst(13).prefix(2))
        return "\(name) · \(yyyy)-\(mm)-\(dd) \(HH):\(MM):\(SS)"
    }

    private func formatChatSessionLine(chatId: String, info: LogMonitor.ChatSessionInfo, df: DateFormatter) -> String {
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
        let shown: String
        if !workspace.isEmpty && workspace != display {
            shown = "\(workspace) · \(display)"
        } else if !workspace.isEmpty {
            shown = workspace
        } else if !info.title.isEmpty {
            shown = display
        } else {
            shown = "会话 ·" + shortId
        }
        return "\(marker)  \(shown)  [\(time)]"
    }

    @objc func quitAll() {
        NSApplication.shared.terminate(nil)
    }
}
