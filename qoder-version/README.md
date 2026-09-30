# qoder-status-bar [powered by ai]

macOS 菜单栏状态指示器（Trae 版的 Qoder IDE 移植）：监控 Qoder 的 `agent.log`，
实时显示每个业务层 chat session 是否正在流式输出。聚合图标、跨窗口去重、轮转自愈、
看门狗兜底等机制与上层 trae-status-bar 完全一致，仅日志来源解析不同。

## 与 Trae 版的差异（通过 `LogSource` 抽象隔离）

| 维度 | Trae | Qoder |
|------|------|-------|
| 每窗口 AI 日志 | `windowN/renderer.log` | `windowN/agent.log` |
| 会话 id 形态 | 20+ 位十六进制 | UUID |
| 流开始 | `[ai-chat/v2] Stream started` | `[ChatSessionService] ACP Stream Started` / `[ACPProgressStateMachine] prompting -> streaming` |
| 流结束 | `Stream finalized / stopped` | `streaming -> completed` / `-> cancelled`、`ACP stream completed` |
| 标题 | `Session updated {title}` | `[ChatViewManagerService] Updated tab title for session <id>: <title>` |
| 工作区 | `workspace_path` JSON | `[Terminal] ... sessionId=<id>, cwd=/abs/path`（与 id 同行） |
| 日志根目录 | `~/Library/Application Support/Trae CN/logs` | `~/Library/Application Support/Qoder/logs` 与 `QoderCN/logs`（同时监听两个变体） |

关键实现说明：
- `streaming -> suspended`（等待权限确认）**不**视为结束——智能体仍在进行，保持 running。
- 每个逻辑流在日志里会成对写多行（如 `ACP Stream Started` + `-> streaming`），
  用 `runningWindows: Set` 去重，重复 start/stop 无副作用。
- Qoder reload 后进程参数 `--aha-log-session-time` 指向的旧会话目录可能已被轮转删除，
  因此把进程探测到的 id 与**真实存在**的会话目录求交；交集为空则回退按 mtime 判活。

## 目录结构

```
qoder-version/
├── build.sh                       # 编译（复用 Trae 版 SDK 覆盖层方案）
├── com.qoder.statusbar.plist      # launchd 模板（非自动安装）
└── Sources/qoder-status-bar/
    ├── LogSource.swift            # 来源抽象协议 + 共享宽松字段解析
    ├── QoderLogSource.swift       # Qoder 具体解析规则
    ├── FileWatcher.swift          # 单文件增量监听 + 轮转自愈
    ├── LogMonitor.swift           # 多根/多会话监控、chat session 状态机、看门狗
    ├── AppDelegate.swift          # 菜单栏聚合图标 + 菜单
    └── main.swift                 # 入口
```

要新增其它 IDE 版本，只需再实现一个 `LogSource`，其余层无需改动。

## 编译运行

```bash
./build.sh
./qoder-status-bar      # 前台试跑，菜单栏出现 ⬤ 图标
```

## 常驻后台（launchd）

```bash
# 1) 编辑 com.qoder.statusbar.plist，把路径改成 build.sh 产出的 qoder-status-bar 绝对路径
cp com.qoder.statusbar.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.qoder.statusbar.plist
```

## 查看 / 停止 / 重载

```bash
launchctl list | grep com.qoder.statusbar
launchctl unload ~/Library/LaunchAgents/com.qoder.statusbar.plist
cat /tmp/qoder-status-bar.stdout
# 更新二进制后重新 load 即可
```
