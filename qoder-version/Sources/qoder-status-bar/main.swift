import AppKit
import Foundation

setvbuf(stdout, nil, _IOLBF, 0) // 行缓冲，重定向到文件时日志实时可见

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate(source: QoderLogSource())
app.delegate = delegate
app.run()
