# trae-status-bar [powered by ai]

macOS 菜单栏状态指示器：监控 Trae 的日志，实时显示每个业务层 chat session 是否正在流式输出。

## 功能

- **聚合状态栏**：菜单栏单个图标
  - 空闲：`⬤`（实心圆点）
  - 有 chat session 进行中：`◐N`、`◓N`、`◑N`、`◒N`（旋转动画 + 进行中的 chat session 个数 N）
- **chat session 粒度**：从 `renderer.log` 的 `[ai-chat/v2] Session fetched` / `Session updated` 事件提取每个 chat session 的 `chat_session_id`、`workspace_path`、`title`、`created_at`；从 `[StreamDomainService] Stream started/finalized`、`[NotificationPort] Stream started/stopped` 事件按 `chat_session_id` 追踪流状态。
- **关联名字**：
  - 显示名优先级 = `title` > workspace basename > chat_id 后 6 位短前缀
  - 工作区来源：`workspace_path` → `main_folder` → `local_folder`
  - 标题来源：`Session updated {...title:"..."}`
- **菜单结构**（点图标弹出，平铺，无二级菜单）：
  - 聚合标题：`Trae: N 个会话进行中` / `Trae: 空闲`
  - 按 Trae 应用启动会话（logs 目录）分组，每组一个不可点击的 header
  - 每个 chat session 一行：`▶/○  workspace · title  [HH:MM]`
  - `Quit trae-status-bar`
- **跨窗口去重**：同一 `chat_session_id` 可能在多个 Trae 窗口（`windowN/renderer.log`）共享，stream start/stop 事件每个窗口都会写一份。用 `runningWindows: Set<windowPath>` 记录"哪些 window 还在跑"，**任何一个 window 收到 stream start 就加入，收到 stream stop 就移出**；只有 `runningWindows` 为空时才彻底变 idle，避免被同一 chat session 的多个 window 的 stop 误清。
- **存活/陈旧判定**：
  - 应用启动会话（logs 目录）：6 小时 (`Config.sessionStaleThreshold`) 内有写入；过期自动忽略，避免堆积
  - 单个 window 目录（`windowN`）：24 小时 (`Config.windowStaleThreshold`) 内无写入视为已关闭，不挂 watcher、不展示
- **卡死兜底（两层）**：
  1. 结束标记覆盖正常/异常/中断路径（`stream.onComplete/onError/onAbort`、`stopType: Complete|Error|Abort|Interrupted`、`event=done`）
  2. 看门狗：chat session 标记为 running 但其 `renderer.log` 文件本身超过 `Config.streamStallTimeout`（默认 300s）再无任何写入，强制把该 window 从 `runningWindows` 移除；窗口消失时也 GC 该 window 在所有 chat session 里的记录

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