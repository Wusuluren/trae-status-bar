# cursor-status-bar [powered by ai]

macOS 菜单栏状态指示器（Trae / Qoder 版的 Cursor IDE 移植）：监控 Cursor 的
`windowN/renderer.log`，实时显示每个业务层 chat session（composer）是否正在
流式输出。聚合图标、跨窗口去重、轮转自愈、看门狗兜底等机制与上层完全一致，
仅日志来源解析不同。

## 与 Trae / Qoder 版的差异（通过 `LogSource` 抽象隔离）

| 维度 | Trae | Qoder | Cursor |
|------|------|-------|--------|
| 每窗口 AI 日志 | `windowN/renderer.log` | `windowN/agent.log` | `windowN/renderer.log` |
| 会话 id 形态 | 20+ 位十六进制 | UUID | UUID（`composerId`） |
| 流开始 | `[ai-chat/v2] Stream started` | `ACP Stream Started` / `-> streaming` | `[ComposerWakelockManager] Acquired wakelock ... reason="agent-loop"` |
| 流结束 | `Stream finalized / stopped` | `-> completed` / `-> cancelled` | `[ComposerWakelockManager] Released wakelock ...`（任意 reason） |
| 标题 | `Session updated {title}` | `Updated tab title for session` | 查 `User/globalStorage/conversation-search.db` 的 `conversations(id, title)`，id 即 composerId |
| 工作区 | `workspace_path` JSON | `[Terminal] ... cwd=` | renderer.log 通常不写；菜单回退到短 id |
| 日志根目录 | `~/Library/Application Support/Trae CN/logs` | `Qoder/logs` 与 `QoderCN/logs` | `~/Library/Application Support/Cursor/logs` |

关键实现说明：
- `Disabled/Restored background throttling` 是 wakelock 伴生事件，**不**触发状态切换。
- 同一 `composerId` 在多轮 agent-loop（工具调用间隙会 Released 再 Acquired）按 set 去重；
  看门狗在日志长时间无写入时强制复位。
- Cursor 进程未必带 `--aha-log-session-time=`；进程探测落空时自动回退 mtime 存活启发式。
- 窗口目录含 `window1`、`window2_wb0`（Agents 窗）等，统一按 `window` 前缀匹配。
- **会话名**：`renderer.log` 只写 `composerId`，不带标题；标题来自 Cursor 的
  ConversationSearch 进程写入的全局 sqlite 库
  `~/Library/Application Support/Cursor/User/globalStorage/conversation-search.db`
  （表 `conversations`，字段 `id` + `title`）。`ConversationTitleResolver.swift`
  直接声明 C 符号并链接 `-lsqlite3` 做只读查询（本机 `/usr/local/include` 的
  sqlite3 头与 SDK 头不兼容，故不走 `import SQLite3`），按 id 缓存，未索引则回退短 id。
- 菜单行展示：`▶/○  <会话名或短id>  [HH:MM]`。

## 目录结构

```
cursor-version/
├── build.sh                        # 编译（复用 Trae 版 SDK 覆盖层方案）
├── com.cursor.statusbar.plist      # launchd 模板（非自动安装）
└── Sources/cursor-status-bar/
    ├── LogSource.swift             # 来源抽象协议 + 共享宽松字段解析
    ├── CursorLogSource.swift       # Cursor 具体解析规则
    ├── FileWatcher.swift           # 单文件增量监听 + 轮转自愈
    ├── LogMonitor.swift            # 多根/多会话监控、chat session 状态机、看门狗
    ├── ConversationTitleResolver.swift # composerId -> 会话标题（只读全局 sqlite 索引库）
    ├── AppDelegate.swift           # 菜单栏聚合图标 + 菜单
    └── main.swift                  # 入口
```

## 编译运行

```bash
./build.sh
./cursor-status-bar      # 前台试跑，菜单栏出现 ⬤ 图标
```

## 常驻后台（launchd）

```bash
# 1) 编辑 com.cursor.statusbar.plist，把路径改成 build.sh 产出的 cursor-status-bar 绝对路径
cp com.cursor.statusbar.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.cursor.statusbar.plist
```

## 查看 / 停止 / 重载

```bash
launchctl list | grep com.cursor.statusbar
launchctl unload ~/Library/LaunchAgents/com.cursor.statusbar.plist
cat /tmp/cursor-status-bar.stdout
# 更新二进制后重新 load 即可
```
