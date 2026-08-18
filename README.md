# trae-status-bar [powered by ai]

macOS 菜单栏状态指示器：监控 Trae 的日志，实时显示每个会话（窗口）是否正在流式输出。

## 功能

- **聚合状态栏**：菜单栏单个图标
  - 空闲：`⬤`（实心圆点）
  - 有会话进行中：`◐N`、`◒N` …（旋转动画 + 进行中的会话个数 N）
- **多会话监控**：监控 `~/Library/Application Support/Trae CN/logs` 下所有"存活"的会话目录
  （每个会话目录 = Trae 的一次应用会话），统计其中正在流式输出的会话个数
- 点击图标弹出菜单：聚合标题（"Trae: N 个会话进行中 / 空闲"）、每个会话的状态
  （会话 ID + 运行中/空闲，子菜单列出各窗口 `windowN` 状态）、Quit
- 会话"存活"判定：目录内任意日志文件在 6 小时内有过写入（`Config.sessionStaleThreshold`，
  可在 `Sources/trae-status-bar/main.swift` 顶部调整），过期会话自动忽略，避免堆积
- 卡死兜底（两层）：① 结束标记覆盖正常/异常/中断路径（`stream.onComplete`、`stream.onError`、
  `stopType: Complete|Error|Abort|Interrupted`、`event=done`）；② 看门狗：某窗口被判定为"运行中"
  但其 renderer.log **文件本身**超过 `Config.streamStallTimeout`（默认 300s）再无任何写入，
  才强制复位为空闲并停止动画。活跃判定用文件修改时间（任何日志写入都算）——真实进行中的会话
  即使暂时不写 `chatStreamService` 心跳行也不会被误杀。

## 编译运行

```bash
./build.sh
```

`build.sh` 会自动处理本机 CommandLineTools 编译器与 SDK 版本不匹配的问题
（swiftc 5.7.1.135.3 vs SDK swiftinterface 5.7.1.134.4），在 `.build/sdkovl` 下
创建打了版本补丁的 SDK 覆盖层后编译。若机器环境正常则直接普通编译。

（旧的一行命令 `swiftc -o trae-status-bar Sources/trae-status-bar/main.swift -framework AppKit`
在当前机器上会因上述版本不匹配失败。）

## 查看状态

launchctl list com.trae.statusbar

## 停止

launchctl unload ~/Library/LaunchAgents/com.trae.statusbar.plist

## 查看日志

cat /tmp/trae-status-bar.stdout

## 重新加载（更新二进制后）

launchctl unload ~/Library/LaunchAgents/com.trae.statusbar.plist
launchctl load ~/Library/LaunchAgents/com.trae.statusbar.plist
