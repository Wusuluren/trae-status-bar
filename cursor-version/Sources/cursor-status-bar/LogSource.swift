import Foundation

// MARK: - 日志来源抽象
/// 把"某个 IDE（Trae / Qoder / Cursor）怎么读它的日志"这件事抽象出来，
/// 让上层的文件监听、会话监控、状态栏 UI 与具体 IDE 解耦。
/// 新增一个 IDE 版本只需实现本协议。

/// 从一条日志行提取到的会话元数据（各字段可缺省，非空即更新）
struct SessionMetadata {
    var chatId: String?
    var title: String?
    var workspacePath: String?
    var createdAt: Date?
}

enum StreamEventKind {
    case start
    case stop
}

/// 一行日志代表的流事件（业务层会话开始/结束输出）
struct StreamEvent {
    let chatId: String
    let kind: StreamEventKind
}

protocol LogSource {
    /// 菜单栏/菜单里显示的 IDE 名字，如 "Trae" / "Qoder" / "Cursor"
    var displayName: String { get }
    /// 会话（应用启动）日志根目录列表（可能多个变体，如国际版 + 国内版），仅监听真实存在的
    var logsBases: [String] { get }
    /// 窗口目录前缀，如 "window"
    var windowDirPrefix: String { get }
    /// 每个窗口目录里要监听的 AI 日志文件名，如 "renderer.log" / "agent.log"
    var windowLogFileName: String { get }
    /// 快速判定：这一行是否包含本来源关心的关键字（做性能短路）
    func interestedIn(_ line: String) -> Bool
    /// 校验会话 id 形态：Trae 为 20+ 位十六进制，Qoder 为 UUID
    func isSessionId(_ id: String) -> Bool
    /// 提取会话元数据（标题 / 工作区 / 创建时间），无则返回 nil
    func extractMetadata(from line: String) -> SessionMetadata?
    /// 提取流开始/结束事件，无则返回 nil
    func extractStreamEvent(from line: String) -> StreamEvent?
    /// 提取日志行前缀时间戳，无则返回 nil。
    /// 默认实现兼容 `2026-10-12 17:03:34.938` 与 ISO `2026-10-15T10:15:05.026+08:00` 两种前缀，
    /// 供上层"会话闲置过期"判定使用；来源可覆写。
    func extractTimestamp(from line: String) -> Date?
}

// MARK: - 共享解析工具
/// 各来源通用的宽松字段提取。渲染端日志里的 JSON 常嵌套 / 转义不全，
/// 所以不做严格解析，直接按 `key` 定位值。
extension LogSource {
    /// 宽松提取 `"key":"value"`：值支持 \/ \" \n \t \uXXXX 等简单转义。
    func extractJSONString(line: String, key: String) -> String? {
        let needle = "\"\(key)\":\""
        guard let r = line.range(of: needle) else { return nil }
        var out = ""
        let chars = Array(line)
        var pos = line.distance(from: line.startIndex, to: r.upperBound)
        while pos < chars.count {
            let c = chars[pos]
            if c == "\\" && pos + 1 < chars.count {
                let next = chars[pos + 1]
                switch next {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/":  out.append("/")
                case "n":  out.append("\n")
                case "t":  out.append("\t")
                case "u":
                    if pos + 5 < chars.count, let code = UInt32(String(chars[pos + 2...pos + 5])) {
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

    /// 提取 `key=value` / `key: value`（值不带引号）形态。
    /// 匹配 `<key>` 后紧跟可选空白、`=` 或 `:`、可选空白、可选左引号，
    /// 然后由 `valueCharSet` 决定值能包含哪些字符，遇分隔字符即止。
    /// - Parameter valueCharSet: 允许出现在值里的额外字符（除字母数字外），如 `/`、`-`、`.`。
    func extractBareString(line: String, key: String, valueCharSet: Set<Character>) -> String? {
        // 宽松定位 key，其后允许可选空格、= 或 :、可选空格、可选左引号
        guard let r = line.range(of: key) else { return nil }
        let chars = Array(line)
        var idx = line.distance(from: line.startIndex, to: r.upperBound)
        // 允许 = 前有空格
        while idx < chars.count && chars[idx] == " " { idx += 1 }
        guard idx < chars.count, chars[idx] == "=" || chars[idx] == ":" else { return nil }
        idx += 1
        while idx < chars.count && (chars[idx] == " " || chars[idx] == "\"") { idx += 1 }
        var out = ""
        while idx < chars.count {
            let c = chars[idx]
            if c == "," || c == " " || c == "}" || c == "\"" || c == "\n" { break }
            // 值必须落在 [字母数字] ∪ valueCharSet 内
            if !(c.isLetter || c.isNumber || valueCharSet.contains(c)) { break }
            out.append(c)
            idx += 1
        }
        return out.isEmpty ? nil : out
    }

    /// 把 `file:///path` 或 `file://path` 归一化成本地路径。
    func normalizeFileURL(_ s: String) -> String {
        if s.hasPrefix("file://") {
            return String(s.dropFirst("file://".count))
        }
        return s
    }

    /// 解析日志行开头的 `yyyy-MM-dd[T| ]HH:mm:ss`。丢弃毫秒与时区：日志与状态栏同机同时区，
    /// 闲置过期以小时为粒度，误差可忽略。解析失败返回 nil，调用方按需回退挂钟时间。
    func extractTimestamp(from line: String) -> Date? {
        let nsRange = NSRange(line.startIndex..., in: line)
        guard let m = lineTimestampRegex.firstMatch(in: line, range: nsRange),
              let r = Range(m.range, in: line) else { return nil }
        var s = String(line[r]).replacingOccurrences(of: "T", with: " ")
        if s.count > 19 { s = String(s.prefix(19)) }
        return lineTimestampFormatter.date(from: s)
    }
}

// MARK: - 时间戳解析共享资源
/// 文件级常量：protocol extension 不能持有存储属性，故放此处，方法内引用。
private let lineTimestampRegex = try! NSRegularExpression(
    pattern: #"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}"#)
private let lineTimestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()
