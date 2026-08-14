# trae-status-bar [powered by ai]

macOS 菜单栏状态指示器：监控 Trae 的日志，实时显示每个会话（窗口）是否正在流式输出。

## 功能

- **多会话支持**：监控 `~/Library/Application Support/Trae CN/logs` 下所有"存活"的会话目录
  （每个会话目录 = Trae 的一次应用会话），每个会话在菜单栏**独立显示**一个图标：
  - 空闲：`14:56 ⬤`（会话启动时刻 + 实心圆点）
  - 运行中：`14:56 ◐◓◑◒`（旋转动画）
- 点击图标弹出该会话的菜单：会话 ID、各窗口状态（`windowN: 运行中/空闲`）、Quit
- 会话"存活"判定：目录内任意日志文件在 6 小时内有过写入（`Config.sessionStaleThreshold`，
  可在 `Sources/trae-status-bar/main.swift` 顶部调整），过期会话自动从菜单栏移除，避免堆积
- 安全超时：某个会话持续动画但 90 秒内无任何日志活动，自动停止动画（防止卡死）

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
