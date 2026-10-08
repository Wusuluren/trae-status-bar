# agent-status-bar [powered by ai]

macOS 菜单栏状态指示器：**Trae / Qoder / Cursor 三个 IDE 版本的功能合并版**。
单进程同时监控三个 IDE 的日志，一个图标聚合显示所有业务层 chat session 是否正在流式输出。

与 `trae-version` / `qoder-version` / `cursor-version` 三个独立版本行为等价，
区别只在于：独立版本每个 IDE 一个进程、一个图标；本版本一个进程、一个聚合图标。

## 聚合行为

- **状态栏图标**：`⬤` 空闲；`◐N`、`◓N`、`◑N`、`◒N` 旋转动画 + **三个 IDE 合计**进行中的 chat session 个数 N
- **菜单结构**（点图标弹出）：
  - 聚合标题：`Agent: N 个会话进行中` / `Agent: 空闲`
  - 按 IDE 来源分组，组间排序 = 有运行会话的来源优先，其次组内最新活跃
    - 来源 header：`Trae: 2 个进行中` / `Qoder: 空闲`（不可点击）
    - 组内按应用启动会话（logs 目录）再分组，header 如 `Cursor · 2026-10-08 11:08:41`
    - 每个 chat session 一行：`▶/○  workspace · title  [HH:MM]`
  - `Quit agent-status-bar`
- 日志根目录不存在的来源自动跳过，互不影响；某个 IDE 没开时菜单里不出现其分组

## 架构（合并做了什么）

以 `cursor-version` 的多文件架构（`LogSource` 抽象 + 通用 `LogMonitor`）为基座：

1. **`TraeLogSource`**：把 `trae-version` 单文件 main.swift 里的解析规则
   （`[ai-chat/v2]` / `[chatStreamService]` 标记、20+ 位十六进制会话 id、
   `Session fetched/updated` 元数据、毫秒 `created_at`）提取为 `LogSource` 实现，
   聚合图标 / 跨窗口去重 / 轮转自愈 / 看门狗等机制复用共享层，未重复实现。
2. **`LogMonitor` 从单来源改为多来源**：同时挂三个来源的 watcher，
   会话按 `来源名|会话路径` 唯一标识，全局聚合计数；
   `--aha-log-session-time=` 进程存活探测按来源独立求交，落空回退 mtime 启发式。
3. **标题外部解析改为按来源声明**：`ChatTitleResolving` 协议 +
   `LogMonitor.resolveMissingTitles()` 动态检测，只有 Cursor 来源接
   `conversation-search.db`（sqlite 只读查询，`-lsqlite3`），Trae / Qoder 走日志行内标题。

## 与三个独立版本的差异对照

| 维度 | Trae | Qoder | Cursor | 合并版 |
|------|------|-------|--------|--------|
| 每窗口 AI 日志 | `windowN/renderer.log` | `windowN/agent.log` | `windowN/renderer.log` | 按来源各自监听 |
| 会话 id 形态 | 20+ 位十六进制 | UUID | UUID（`composerId`） | 按来源各自校验 |
| 流开始 | `[ai-chat/v2] Stream started` 等 | `ACP Stream Started` / `-> streaming` | `Acquired wakelock reason="agent-loop"` | 按来源各自解析 |
| 流结束 | `Stream finalized / stopped` 等 | `-> completed / cancelled`（`suspended` 不算） | `Released wakelock`（任意 reason） | 同上 |
| 标题 | `Session updated {title}` | `Updated tab title for session` | 查 conversation-search.db | 同上（外部解析仅 Cursor） |
| 日志根目录 | `Trae CN/logs`（回退 `Trae/logs`） | `Qoder/logs` 与 `QoderCN/logs` | `Cursor/logs` | 全部监听 |

## 目录结构

```
agent-version/
├── build.sh                        # 编译（复用 SDK 覆盖层方案，追加 -lsqlite3）
├── com.agent.statusbar.plist       # launchd 模板（非自动安装）
└── Sources/agent-status-bar/
    ├── LogSource.swift             # 来源抽象协议 + 共享宽松字段解析 + ChatTitleResolving
    ├── TraeLogSource.swift         # Trae 解析规则（自 trae-version 单文件版提取）
    ├── QoderLogSource.swift        # Qoder 解析规则
    ├── CursorLogSource.swift       # Cursor 解析规则（并接 ConversationTitleResolver）
    ├── FileWatcher.swift           # 单文件增量监听 + 轮转自愈
    ├── LogMonitor.swift            # 多来源/多会话监控、chat session 状态机、看门狗
    ├── ConversationTitleResolver.swift # composerId -> 会话标题（只读全局 sqlite 索引库）
    ├── AppDelegate.swift           # 聚合菜单栏图标 + 按来源分组菜单
    └── main.swift                  # 入口（注册三个来源）
```

## 编译运行

```bash
./build.sh
./agent-status-bar      # 前台试跑，菜单栏出现一个 ⬤ 聚合图标
```

## 常驻后台（launchd）

```bash
# 与三个独立版本的 plist 互斥（会同时出现多个图标），启用本版本前先卸载旧的：
#   launchctl unload ~/Library/LaunchAgents/com.trae.statusbar.plist
cp com.agent.statusbar.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.agent.statusbar.plist
```

## 查看 / 停止 / 重载

```bash
launchctl list com.agent.statusbar
launchctl unload ~/Library/LaunchAgents/com.agent.statusbar.plist
cat /tmp/agent-status-bar.stdout
# 更新二进制后重新 load 即可
```
