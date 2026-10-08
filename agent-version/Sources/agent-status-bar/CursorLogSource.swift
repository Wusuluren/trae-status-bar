import Foundation

/// Cursor IDE 的日志来源。
///
/// 与 Trae / Qoder 的差异（均基于本机真实 `windowN/renderer.log` 逆向得到）：
/// - 每个窗口的 AI 日志仍是 `windowN/renderer.log`（与 Trae 同名；Qoder 是 `agent.log`）
/// - 会话 id（composerId）是 UUID
/// - 流开始：`[ComposerWakelockManager] Acquired wakelock ... reason="agent-loop"|"agent-loop-resumed" composerId=<uuid>`
/// - 流结束：`[ComposerWakelockManager] Released wakelock ... reason="generation-ended" composerId=<uuid>`
///   （`reason="user-approval-requested"` 的释放是等待授权、会话未结束，忽略以保持转圈；
///    其余 Released 视为结束，避免 abort/error 漏清）
/// - 标题 / 工作区：renderer.log 里通常不写业务标题；展示层回退到 workspace basename 或短 id
/// - 日志根目录：`~/Library/Application Support/Cursor/logs`
/// - 窗口目录：`window1`、`window2_wb0`（Agents 窗）等，前缀均为 `window`
struct CursorLogSource: LogSource {
    let displayName = "Cursor"
    let windowDirPrefix = "window"
    let windowLogFileName = "renderer.log"

    /// 候选日志根目录，仅保留真实存在的
    let logsBases: [String]

    private static let candidates: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/Library/Application Support/Cursor/logs",
        ]
    }()

    init() {
        let fm = FileManager.default
        self.logsBases = Self.candidates.filter { fm.fileExists(atPath: $0) }
    }

    init(logsBases: [String]) {
        self.logsBases = logsBases
    }

    private static let tags = [
        "[ComposerWakelockManager]",
    ]

    func interestedIn(_ line: String) -> Bool {
        Self.tags.contains { line.contains($0) }
    }

    private static let uuidRegex = try! NSRegularExpression(
        pattern: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#)

    func isSessionId(_ id: String) -> Bool {
        Self.uuidRegex.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil
    }

    // MARK: 流事件

    func extractStreamEvent(from line: String) -> StreamEvent? {
        guard line.contains("[ComposerWakelockManager]") else { return nil }

        let kind: StreamEventKind
        if line.contains("Acquired wakelock"),
           line.contains("reason=\"agent-loop\"") || line.contains("reason=\"agent-loop-resumed\"") {
            // agent-loop（首次开始）/ agent-loop-resumed（授权后恢复）都视为运行中
            kind = .start
        } else if line.contains("Released wakelock") {
            // 等待用户授权时 wakelock 会以 user-approval-requested 释放，但会话并未结束：
            // 忽略该释放，保持转圈，直到授权后 agent-loop-resumed 重新获取。
            if line.contains("reason=\"user-approval-requested\"") { return nil }
            // generation-ended / abort / 其它释放路径一律 stop
            kind = .stop
        } else {
            // Disabled/Restored background throttling 是伴生事件，忽略
            return nil
        }

        guard let chatId = extractBareString(line: line, key: "composerId", valueCharSet: ["-"]),
              isSessionId(chatId) else { return nil }
        return StreamEvent(chatId: chatId, kind: kind)
    }

    // MARK: 元数据

    /// Cursor 的 renderer.log 基本不写 composer 标题/工作区；保留钩子以便日后扩展。
    func extractMetadata(from line: String) -> SessionMetadata? {
        _ = line
        return nil
    }
}

// MARK: - ChatTitleResolving
/// Cursor 标题来自全局对话索引库 conversation-search.db（见 ConversationTitleResolver）。
/// 库缺失/打不开时 init? 返回 nil，不注册 → LogMonitor 动态检测不到，菜单回退短 id。
extension CursorLogSource: ChatTitleResolving {
    private static let resolver: ConversationTitleResolver? = ConversationTitleResolver()

    func resolveTitle(chatId: String) -> String? {
        Self.resolver?.title(for: chatId)
    }
}
