import AppKit
import Foundation

setvbuf(stdout, nil, _IOLBF, 0) // 行缓冲，重定向到文件时日志实时可见

// 三个 IDE 来源并存：日志根目录不存在的来源自动跳过，互不影响
let sources: [any LogSource] = [TraeLogSource(), QoderLogSource(), CursorLogSource()]

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate(sources: sources)
app.delegate = delegate
app.run()
