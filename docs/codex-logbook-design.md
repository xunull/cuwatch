# Codex Logbook — Design Doc

**状态**：v0.1 设计已锁定 2026-06-26，实施中
**Anchor 演化**：from "This menu bar app is a meter." → **"A meter at a glance, a logbook at a click."**
**姊妹文档**：
- [`docs/codex-row-real-vs-estimated.md`](./codex-row-real-vs-estimated.md)（dial 的 real-but-stale 问题）
- [`docs/popover-deadlock-fix-plan.md`](./popover-deadlock-fix-plan.md)（之前的并发修复）
- [`DESIGN.md`](../DESIGN.md) §"Logbook slide-in panel"（视觉锁定）

---

## 一句话总结

cuwatch 在 popover footer 加一个 **"Logbook"** 链接。点开后从右滑入 340pt 宽的面板，显示 Codex 本机历史聚合：累计 token、峰值 thread token、活跃天数、当前连续天数、最长连续天数。数据来自 `~/.codex/state_5.sqlite::threads`。**不**是 Codex.app 跨设备聚合 —— 是这台 Mac 上的真实活动统计。

---

## 动机（office-hours 讨论的结果）

2026-06-25 用户看到 Codex.app 桌面 UI 显示的统计：

- 34.8 亿 累计 Token
- 2.3 亿 峰值 Token
- 25 小时 50 分 最长任务
- 0 天 当前连续天数
- 31 天 最长连续天数

用户问：能不能从 Codex 应用的本地 DB 取这些数据？

### 调研发现

`~/.codex/state_5.sqlite::threads` 表里有：
- `tokens_used INTEGER` —— 每个 thread 累计 token 数，实时更新
- `created_at`, `updated_at` —— 时间戳
- `thread_source` —— `user` / `subagent` / NULL
- 等等

但**数字与 Codex.app UI 不一致**：

| 统计 | Codex.app UI | 本机 SQLite |
|------|--------------|-------------|
| 累计 Token | 34.8 亿 | 50.5 亿 |
| 峰值 Token | 2.3 亿 | 3.12 亿 |
| 最长连续 | 31 天 | 16 天 |

**决定性证据是 streak**：本机日期间有 gap，最长连续 16 天；UI 显示 31 天 → 必然来自**服务端跨设备聚合**。

### 用户动机的选择

office-hours 里逼出来：用户的动机不是"被 stale 数据坑过"（A），不是"填工程坑"（C），而是 **B：看到 Codex.app 那些好数字想让 cuwatch 也能显示**。

---

## Anchor 演化

旧 anchor：`"This menu bar app is a meter."`

显示历史聚合 = 添加表盘以外的信息，技术上违反 meter 的纯粹性。

新 anchor：**`"A meter at a glance, a logbook at a click."`**

理由：
- 保留 meter 的 identity（菜单栏图标 + popover 主体不动）
- 加入 logbook 的扩展（slide-in Stats 面板）
- "at a glance" / "at a click" 明示分层访问 —— 默认看不到 stats
- **logbook 是 craftsman 词汇，不是 SaaS 词汇**：log 是**你写**的，dashboard 是**给你看**的。cuwatch 显示的是你的劳作痕迹，不是别人喂给你的数据。

这和原 wedge sentence "The AI usage tracker that refuses to look like an AI tool." 完全一致。

---

## 范围：v0.1 只做 Codex

| 服务 | 本地历史能挖出什么 | v0.1 状态 |
|------|------------------|-----------|
| **Claude** | `~/.claude/projects/**/*.jsonl` 逐 message token 数 | **延后 v1.1+** |
| **Codex** | `~/.codex/state_5.sqlite::threads` | **v0.1 实施** |
| **Minimax** | API 不提供，本地不存 | 延后或永不做 |

三服务对等是 DESIGN.md 的硬约束，但**视觉层对等 ≠ 数据深度对等**。Logbook 只显示 Codex 是诚实的范围限制 —— 用户动机本来就是 Codex.app 数字。三服务对等等到 v1.1。

---

## v0.1 显示的 5 个数字

| 字段 | 数据来源 | 公式 |
|------|---------|------|
| 累计 Token | `SUM(tokens_used) FROM threads` | 全表求和 |
| 峰值 Token (单 thread) | `MAX(tokens_used) FROM threads` | 全表 max |
| 活跃天数 | `COUNT(DISTINCT date(created_at)) / (now - first_date) 天数` | 显示 "57 / 63" 形式 + 起始日期 |
| 当前连续 | distinct dates 倒序找今天到不连续断点的距离 | 0 表示今天没用 |
| 最长连续 | distinct dates 找最长 run | 单位天 |

**故意删掉**：最长任务（Codex.app UI 显示 25h 50m，但 SQLite 的 `MAX(updated_at - created_at)` 算出来是 888h —— thread 长时间挂着不退出，数据本身无法支持诚实定义）。

---

## ASCII Mockup（340pt × 自适应高度）

```
┌────────────────────────────────────┐
│                                    │
│  CODEX · LOGBOOK         (xs ink-mute)
│                                    │
│  ─────────                         │
│                                    │
│  累计 TOKEN              (xs ink-dim uppercase)
│  5.05B                   (display 34pt ink monospaced)
│                                    │
│  峰值 TOKEN · 单 THREAD            │
│  312M                    (xl 22pt) │
│                                    │
│  活跃天数                          │
│  57 / 63                 (xl 22pt) │
│  自 2026-04-24           (s 11pt ink-dim)
│                                    │
│  最长连续 · 当前连续               │
│  16 d  ·  0 d            (xl 22pt) │
│                                    │
│  ─────────               (hairline)│
│                                    │
│  本机 · 此账号 · CLI + Codex.app  (s 11pt ink-mute)
│  Codex.app 显示的是跨设备聚合，    │
│  数字会和上面不同                  │
│                                    │
│                          [← Back]  (s 11pt link)
└────────────────────────────────────┘
```

数字格式：英文 B/M 而非中文亿（cuwatch 整体英文 UI）。

---

## DESIGN.md 改动清单（已完成）

1. ✅ 第 4 行 anchor 句更新为 "A meter at a glance, a logbook at a click."
2. ✅ Popover composition spec 加 footer "Logbook" 链接（第 118-122 行）
3. ✅ 新增 Logbook slide-in panel 规格
4. ✅ Anti-list 加 "What is NOT allowed in the logbook"（防 SaaS 化）
5. ✅ Decisions Log 加 2026-06-26 条目
6. ✅ Living Document 段落更新

---

## 实施阶段

| 阶段 | 范围 | 状态 |
|------|------|------|
| 1 | DESIGN.md 改动 | ✅ |
| 2 | 写本设计文档 | ✅（你正在读） |
| 3 | `CodexLogbookReader` 实现 | 进行中 |
| 4 | `CodexLogbookReaderTests`（5 + 兜底） | 待办 |
| 5 | `LogbookView` SwiftUI | 待办 |
| 6 | `PopoverShell` 加 logbook 路由 | 待办 |
| 7 | README 更新 + ship 验证 | 待办 |

---

## Non-goals

- **Claude / Minimax logbook**：v0.1 不做，v1.1+ 议程
- **Chart / Sparkline / 时间序列可视化**：永远不做（DESIGN.md anti-list 锁定）
- **跨设备聚合**：永远不做（这就是和 Codex.app UI 的核心差异点 —— 本机统计是 cuwatch 的承诺）
- **数据持久化**：Logbook 是 reader，不写任何文件。所有数据从 SQLite 实时读
- **历史导出/CSV**：v0.1 不做
- **可配置过滤（按项目/分支）**：v0.1 不做

---

## Open questions / 后续可能议程

1. **Multi-account**：如果用户在 Codex CLI 里 logout/login 多个账号，`state_5.sqlite` 的 threads 会混在一起。我们目前不区分账号。v0.1 接受这点；v0.x 可加按 `account_id` filter（需要先弄清 SQLite 里是不是有这字段 —— `remote_control_enrollments` 表有 `account_id` 但 `threads` 表没有直接关联）
2. **DB schema 演化**：文件名 `state_5.sqlite` 表明 OpenAI 已经迭代过 5 个 schema。一旦改成 `state_6` 我们 break。需要 graceful 探测（v0.x 加 fallback：扫所有 `state_*.sqlite` 选最新一个）
3. **Codex CLI 删除 archived threads**：如果 codex CLI 提供归档清理，cuwatch 累计 token 会下降。这是预期行为还是 bug？v0.1 接受降，"累计"等于"DB 里现存的累计"

---

**Last updated**：2026-06-26（设计 + 实施过程中）
