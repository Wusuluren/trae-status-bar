import AppKit

/// 菜单栏聚合状态指示器：同时监控 Trae / Qoder / Cursor 三个 IDE，
/// 单图标聚合显示所有来源进行中的 chat session 总数，菜单按来源分组平铺。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let sources: [any LogSource]
    private var statusItem: NSStatusItem!
    private var monitor: LogMonitor?
    private var isAnimating = false
    private var timer: Timer?
    private var frameIndex = 0
    private let frames = ["◐", "◓", "◑", "◒"]

    private var activeCount: Int { monitor?.activeSessionCount ?? 0 }

    init(sources: [any LogSource]) {
        self.sources = sources
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        statusItem.button?.toolTip = "AI IDE 会话状态（Trae / Qoder / Cursor）"
        statusItem.menu = NSMenu()
        setTitle("⬤")
        rebuildMenu()

        monitor = LogMonitor(sources: sources)
        monitor?.onSessionAdded = { [weak self] _ in self?.rebuildMenu() }
        monitor?.onSessionRemoved = { [weak self] _ in self?.rebuildMenu() }
        monitor?.onChatSessionStart = { [weak self] _, _ in self?.syncState() }
        monitor?.onChatSessionStop = { [weak self] _, _ in self?.syncState() }
        monitor?.start()

        // 周期性刷新菜单（title / workspace 可能在会话启动后才写出来）
        Timer.scheduledTimer(withTimeInterval: Config.rescanInterval, repeats: true) { [weak self] _ in
            self?.monitor?.resolveMissingTitles()
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
        print("[agent-status-bar] Animation started (active sessions: \(activeCount))")
    }

    private func stopAnimation() {
        guard isAnimating else { return }
        isAnimating = false
        timer?.invalidate()
        timer = nil
        setTitle("⬤")
        print("[agent-status-bar] Animation stopped")
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

    /// 重建菜单：聚合标题 + 按 IDE 来源分组，组内再按应用启动会话分组平铺。
    /// 来源 header 形如 `Trae: 2 个进行中` / `Qoder: 空闲`。
    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let agg = activeCount > 0 ? "Agent: \(activeCount) 个会话进行中" : "Agent: 空闲"
        menu.addItem(NSMenuItem(title: agg, action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        let all = monitor?.allChatSessions() ?? []
        if all.isEmpty {
            menu.addItem(NSMenuItem(title: "（暂无存活会话）", action: nil, keyEquivalent: ""))
        } else {
            let df = DateFormatter()
            df.dateFormat = "HH:mm"
            var currentSourceName: String? = nil
            var currentSessionKey: String? = nil
            for entry in all {
                if entry.sourceName != currentSourceName {
                    currentSourceName = entry.sourceName
                    currentSessionKey = nil
                    let n = monitor?.activeCount(forSourceNamed: entry.sourceName) ?? 0
                    let headerTitle = n > 0
                        ? "\(entry.sourceName): \(n) 个进行中"
                        : "\(entry.sourceName): 空闲"
                    let header = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
                    header.isEnabled = false
                    menu.addItem(header)
                }
                if entry.sessionId != currentSessionKey {
                    currentSessionKey = entry.sessionId
                    let sub = NSMenuItem(title: formatAppSessionLabel(entry.sourceName, entry.dirName),
                                         action: nil, keyEquivalent: "")
                    sub.isEnabled = false
                    menu.addItem(sub)
                }
                let line = formatChatSessionLine(chatId: entry.chatId, info: entry.info, df: df)
                menu.addItem(NSMenuItem(title: line, action: nil, keyEquivalent: ""))
            }
        }

        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit agent-status-bar", action: #selector(quitAll), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// 会话目录末段（如 20260929T161645）→ "Trae · 2026-09-29 16:16:45"；形态不符时回退原名
    private func formatAppSessionLabel(_ sourceName: String, _ dirName: String) -> String {
        guard dirName.count >= 15, dirName.hasPrefix("20") else { return "\(sourceName) · \(dirName)" }
        let yyyy = String(dirName.prefix(4))
        let mm = String(dirName.dropFirst(4).prefix(2))
        let dd = String(dirName.dropFirst(6).prefix(2))
        let HH = String(dirName.dropFirst(9).prefix(2))
        let MM = String(dirName.dropFirst(11).prefix(2))
        let SS = String(dirName.dropFirst(13).prefix(2))
        return "\(sourceName) · \(yyyy)-\(mm)-\(dd) \(HH):\(MM):\(SS)"
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
