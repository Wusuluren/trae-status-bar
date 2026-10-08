import Foundation

/// Trae IDE 的日志来源。
///
/// 解析规则取自 trae-version 的单文件实现（基于本机真实 renderer.log 逆向得到）：
/// - 每个窗口的 AI 日志是 `windowN/renderer.log`（Qoder 是 `agent.log`）
/// - 会话 id 是 20+ 位十六进制（Qoder / Cursor 是 UUID）
/// - 元数据：`[ai-chat/v2]` 的 Session fetched / Session updated 事件，
///   提取 `chat_session_id` / `title` / `workspace_path`（回退 main_folder / local_folder）/ `created_at`（毫秒）
/// - 流开始：`[StreamDomainService] Stream started` / `[NotificationPort] Stream started`（chat session 维度），
///   以及旧版 `[chatStreamService]` 系列标记（窗口维度兜底）
/// - 流结束：`Stream finalized / stopped`、`stream.onComplete/onError/onAbort`、
///   `stopType: Complete|Error|Abort|Interrupted`、`event=done` 等，覆盖正常/异常/中断路径
struct TraeLogSource: LogSource {
    let displayName = "Trae"
    let windowDirPrefix = "window"
    let windowLogFileName = "renderer.log"

    /// 候选日志根目录（国内版 + 国际版），仅保留真实存在的
    let logsBases: [String]

    private static let candidates: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/Library/Application Support/Trae CN/logs",
            "\(home)/Library/Application Support/Trae/logs",
        ]
    }()

    init() {
        let fm = FileManager.default
        self.logsBases = Self.candidates.filter { fm.fileExists(atPath: $0) }
    }

    init(logsBases: [String]) {
        self.logsBases = logsBases
    }

    // 关心的服务标签，做性能短路
    private static let tags = [
        "[chatStreamService]",
        "[ai-chat/v2]",
    ]

    func interestedIn(_ line: String) -> Bool {
        Self.tags.contains { line.contains($0) }
    }

    /// Trae 会话 id：20+ 位十六进制
    func isSessionId(_ id: String) -> Bool {
        id.count >= 20 && id.allSatisfy { $0.isHexDigit }
    }

    // MARK: 流事件

    func extractStreamEvent(from line: String) -> StreamEvent? {
        guard line.contains("[ai-chat/v2]") else { return nil }
        guard let chatId = extractJSONString(line: line, key: "sessionId")
            ?? extractChatSessionIdFromTail(line: line),
            isSessionId(chatId) else { return nil }

        if isStartMarker(line) { return StreamEvent(chatId: chatId, kind: .start) }
        if isEndMarker(line) { return StreamEvent(chatId: chatId, kind: .stop) }
        return nil
    }

    /// 从形如 `... tailStatus: 6ab0cbed663253458ad9a836` 的尾部提取 chat session id
    /// （[NotificationPort] Stream started, subscribing to tailStatus: <id>）
    private func extractChatSessionIdFromTail(line: String) -> String? {
        guard let r = line.range(of: "tailStatus: ") else { return nil }
        let token = line[r.upperBound...].prefix { $0.isHexDigit }
        return token.isEmpty ? nil : String(token)
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

    // MARK: 元数据

    /// 解析 Session fetched / Session updated / session_updated 等事件，
    /// 提取 chat_session_id / title / workspace_path / created_at。
    func extractMetadata(from line: String) -> SessionMetadata? {
        guard line.contains("[ai-chat/v2]") else { return nil }

        // Session fetched: ... {"chat_session_id":"...","title":"...","workspace_path":"...","created_at":"<ms>"}
        // Session updated: ... {"chat_session_id":"...","title":"..."}（仅更新 title）
        // event: session_updated ... "title":"..."
        guard let chatId = extractJSONString(line: line, key: "chat_session_id"),
              isSessionId(chatId) else { return nil }

        var md = SessionMetadata()
        md.chatId = chatId
        md.title = extractJSONString(line: line, key: "title")
        md.workspacePath = extractJSONString(line: line, key: "workspace_path")
            ?? extractJSONString(line: line, key: "main_folder")
            ?? extractJSONString(line: line, key: "local_folder")
        if let ms = extractJSONString(line: line, key: "created_at"), let v = TimeInterval(ms) {
            // Trae 的 created_at 是毫秒
            if v > 1_000_000_000_000 { md.createdAt = Date(timeIntervalSince1970: v / 1000.0) }
            else if v > 1_000_000_000 { md.createdAt = Date(timeIntervalSince1970: v) }
        }
        // 只有该行明确带 title/workspace/created_at 之一，才视为元数据事件
        guard md.title != nil || md.workspacePath != nil || md.createdAt != nil else { return nil }
        return md
    }
}
