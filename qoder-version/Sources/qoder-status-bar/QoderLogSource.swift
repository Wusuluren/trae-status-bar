import Foundation

/// Qoder IDE 的日志来源。
///
/// 与 Trae 的差异（均基于本机真实 agent.log 逆向得到）：
/// - 每个窗口的 AI 日志是 `windowN/agent.log`（Trae 是 `renderer.log`）
/// - 会话 id 是 UUID（Trae 是 20+ 位十六进制）
/// - 流开始：`[ChatSessionService] ACP Stream Started: sessionId=<uuid>, ...`
///            或 `[ACPProgressStateMachine] State transition: prompting -> streaming, ... sessionId: <uuid>`
/// - 流结束：`[ChatSessionService] ACP stream completed: {"sessionId":"<uuid>",...}`
///            或 `[ACPProgressStateMachine] State transition: streaming -> completed|cancelled, ... sessionId: <uuid>`
///            注意 `-> suspended`（等待权限确认）不是结束，智能体仍在进行，不能置为空闲。
/// - 标题：`[ChatViewManagerService] Updated tab title for session <uuid>: <title>`
/// - 工作区：`[Terminal] ... sessionId=<uuid>, cwd=/abs/path, ...`（与 sessionId 同行）
struct QoderLogSource: LogSource {
    let displayName = "Qoder"
    let windowDirPrefix = "window"
    let windowLogFileName = "agent.log"

    /// 候选日志根目录（国际版 + 国内版），仅保留真实存在的
    let logsBases: [String]

    private static let candidates = [
        "/Users/wav/Library/Application Support/Qoder/logs",
        "/Users/wav/Library/Application Support/QoderCN/logs",
    ]

    init() {
        let fm = FileManager.default
        self.logsBases = Self.candidates.filter { fm.fileExists(atPath: $0) }
    }

    init(logsBases: [String]) {
        self.logsBases = logsBases
    }

    // 关心的服务标签，做性能短路
    private static let tags = [
        "[ChatSessionService]",
        "[ACPProgressStateMachine]",
        "[ChatViewManagerService]",
        "[Terminal]",
    ]

    func interestedIn(_ line: String) -> Bool {
        Self.tags.contains { line.contains($0) }
    }

    // UUID 形态校验
    private static let uuidRegex = try! NSRegularExpression(
        pattern: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#)

    func isSessionId(_ id: String) -> Bool {
        Self.uuidRegex.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil
    }

    // MARK: 流事件

    func extractStreamEvent(from line: String) -> StreamEvent? {
        let isStateMachine = line.contains("[ACPProgressStateMachine]") && line.contains("State transition:")
        let isChatService = line.contains("[ChatSessionService]")

        var kind: StreamEventKind?
        if isChatService && line.contains("ACP Stream Started") {
            kind = .start
        } else if isChatService && line.contains("ACP stream completed") {
            kind = .stop
        } else if isStateMachine {
            // 只有进入 streaming 是 start；completed / cancelled 是 stop。
            // suspended（等待权限）保持运行态，忽略。
            if line.contains("-> streaming") {
                kind = .start
            } else if line.contains("-> completed") || line.contains("-> cancelled") {
                kind = .stop
            }
        }
        guard let k = kind else { return nil }
        guard let chatId = extractSessionId(from: line), isSessionId(chatId) else { return nil }
        return StreamEvent(chatId: chatId, kind: k)
    }

    // MARK: 元数据

    private static let titleRegex = try! NSRegularExpression(
        pattern: #"Updated tab title for session ([0-9a-fA-F-]{30,38}):\s*(.+)$"#)

    func extractMetadata(from line: String) -> SessionMetadata? {
        var md = SessionMetadata()

        // 标题：仅来自 ChatViewManagerService 的 "Updated tab title for session <uuid>: <title>"
        if line.contains("[ChatViewManagerService]") {
            let range = NSRange(line.startIndex..., in: line)
            if let m = Self.titleRegex.firstMatch(in: line, range: range),
               let idR = Range(m.range(at: 1), in: line),
               let tR = Range(m.range(at: 2), in: line) {
                let id = String(line[idR])
                if isSessionId(id) {
                    md.chatId = id
                    var title = String(line[tR]).trimmingCharacters(in: .whitespaces)
                    // 去掉可能拖尾的元信息（该行一般到标题即止，保守截断逗号后内容）
                    if let comma = title.firstIndex(of: ",") {
                        title = String(title[..<comma]).trimmingCharacters(in: .whitespaces)
                    }
                    if !title.isEmpty { md.title = title }
                }
            }
        }

        // 工作区：来自 [Terminal] 行，sessionId 与 cwd 同行
        if md.chatId == nil, line.contains("[Terminal]"), line.contains("cwd="),
           let id = extractSessionId(from: line), isSessionId(id),
           let cwd = extractBareString(line: line, key: "cwd", valueCharSet: ["/", ".", "-", "_", "~"]) {
            md.chatId = id
            md.workspacePath = normalizeFileURL(cwd)
        }

        guard md.chatId != nil else { return nil }
        // 只有确实带来 title/workspace 之一才算元数据事件
        guard md.title != nil || md.workspacePath != nil else { return nil }
        return md
    }

    // MARK: 私有

    /// 从一行取 sessionId：先试 JSON `"sessionId":"..."`，再试裸格式 `sessionId=<uuid>` / `sessionId: <uuid>`。
    private func extractSessionId(from line: String) -> String? {
        if let j = extractJSONString(line: line, key: "sessionId"), isSessionId(j) {
            return j
        }
        if let b = extractBareString(line: line, key: "sessionId", valueCharSet: ["-"]), isSessionId(b) {
            return b
        }
        return nil
    }
}
