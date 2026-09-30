import Foundation

/// 单个日志文件的增量监听器：事件驱动读取新追加内容，
/// 并处理 10MB 轮转（renderer/agent.log 写满被 rename 后新建同名文件，旧 fd 失联）。
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

    /// 新挂载时从头读取整个当前日志。
    /// 标题（Updated tab title）、工作区（cwd）等元数据只在会话开头写一次，
    /// 随日志变长会被尾部窗口甩掉，故初始化时全量回放；从字节 0 起读也天然规避 UTF-8 半字符问题。
    func readAll() {
        guard let handle = fileHandle else { return }
        handle.seek(toFileOffset: 0)
        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty, let content = decodeUTF8(data) else { return }
        onNewLines?(content)
    }

    /// 宽松 UTF-8 解码：若起点切在多字节字符中间导致整段解码失败，
    /// 丢弃到第一个换行符后再解（首行本就是残缺行，丢弃无损）。
    private func decodeUTF8(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        if let nl = data.firstIndex(of: 0x0A), nl + 1 < data.count {
            return String(data: data[(nl + 1)...], encoding: .utf8)
        }
        return nil
    }

    /// 轮转自愈：轮转后旧 fd 指向被换走的 inode，永远收不到写入事件。
    /// 由定时器周期调用，按 inode 变化重新挂载并回放新文件，避免状态卡死。
    func reopenIfNeeded() {
        guard let newInode = Self.getInode(path), newInode != currentInode else { return }
        if let handle = fileHandle {
            let data = handle.readDataToEndOfFile()
            if let content = String(data: data, encoding: .utf8), !content.isEmpty {
                onNewLines?(content)
            }
        }
        openFile(seekToEnd: false)
        guard let handle = fileHandle else { return }
        let data = handle.readDataToEndOfFile()
        if let content = String(data: data, encoding: .utf8), !content.isEmpty {
            onNewLines?(content)
        }
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
