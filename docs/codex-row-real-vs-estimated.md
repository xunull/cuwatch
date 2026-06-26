# Codex 行：真实数据 vs 估算

**状态**：说明性文档 —— 记录当前行为，不提议代码改动
**撰写**：2026-06-25 讨论 Codex 使用量数据来源时
**姊妹文档**：
- [`docs/claude-statusline-rate-limits.md`](./claude-statusline-rate-limits.md)
  （Claude rate_limits 来源）
- [`docs/popover-deadlock-fix-plan.md`](./popover-deadlock-fix-plan.md)
  （popover 并发死锁修复）

---

## 一句话总结

cuwatch 里 Codex 行的两个核心字段：

| 字段 | 来源 | 性质 |
|------|------|------|
| `usedFraction`（dial 百分比） | `payload.rate_limits.primary.used_percent` 来自 rollout JSONL | **真实**服务端数字，冻结在上次 codex CLI 跑的时刻 |
| `resetAt`（重置时间） | `payload.rate_limits.primary.resets_at` 来自 rollout JSONL | **真实**服务端时间戳，新鲜度同上 |

两个字段都有一个 fallback 估算路径（time proxy），但**生产环境几乎不触发** —— 它要求一个非常特殊的边缘情况（有 rollout 文件、最新文件在 5h 内、且最近 5 个文件里**全都没有** `rate_limits` 字段）。任何一个曾经从 codex CLI 收到过服务端响应的账号，走的都是真实路径。

**诚实的表述**：dial 上显示的数字是真值，不是估算，但它**冻结在上一次 codex CLI 调用的时刻**。它**不**反映 Codex.app 桌面客户端的活动 —— 后者写的是另一个数据源（`~/.codex/state_5.sqlite`，见 plan A 讨论）。

---

## 背景 —— 问题的起源

2026-06-25 的两个原话提问：

1. *"现在 codex 计算的 reset 的时间是估算的 还是真实提取出来的?"*
2. *"但是现在 codex 的使用量的那个部分完全是估算的是么?"*

简短回答：**不是估算，但是过时的**。本文展开解释。

---

## 两条代码路径

`Sources/CuwatchCore/Services/Codex/CodexReader.swift:67-89`：

```swift
public func read(now: Date = Date()) -> Result {
    let probe = probeEnvironment()
    switch probe {
    case .binaryNotInstalled, .notAuthenticated:
        return Result(snapshot: nil, probe: probe)
    case .authenticated(let sessionStart):
        // 路径 1：先尝试真实数字
        if let snapshot = makeSnapshotFromRateLimits(now: now) {
            return Result(snapshot: snapshot, probe: probe)
        }
        // 路径 2：回退到 time-proxy
        guard let sessionStart else {
            return Result(snapshot: nil, probe: probe)
        }
        return Result(snapshot: makeTimeBasedSnapshot(...), probe: probe)
    }
}
```

### 路径 1 —— 真实（生产路径）

来源：任何 `~/.codex/sessions/` 下的 rollout JSONL 文件里任意一行的 `payload.rate_limits.primary.{used_percent, resets_at}` 字段。

Codex CLI 在**每次**收到服务端响应时都会写入这两个值。它们是 OpenAI 服务端在那一刻为用户账号算出的**精确**数字 —— 和 Codex.app 桌面 UI 直接问服务端拿到的是同一个数。

cuwatch 是怎么读的（`CodexReader.swift:241-256`）：

```swift
static func lastRateLimits(in url: URL) -> CodexRateLimits? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    ...
    for line in text.split(separator: "\n", ...) {
        ...
        guard let event = any as? [String: Any],
              let payload = event["payload"] as? [String: Any],
              let rate = payload["rate_limits"] as? [String: Any] else { continue }
        if let parsed = CodexRateLimits.from(rate) {
            lastSeen = parsed
        }
    }
    return lastSeen
}
```

`resetAt` 怎么构造（`CodexReader.swift:262-278`）：

```swift
private static func snapshot(from limits: CodexRateLimits, now: Date) -> UsageSnapshot {
    ...
    return UsageSnapshot(
        ...
        resetAt: limits.primaryResetsAt,   // ← 服务端的 Unix epoch
        ...
    )
}
```

`primaryResetsAt` 解码（`CodexReader.swift:297-317`）：

```swift
guard let primary = dict["primary"] as? [String: Any],
      let primaryPct = (primary["used_percent"] as? NSNumber)?.doubleValue,
      ...
      let primaryResetsAt = (primary["resets_at"] as? NSNumber)?.doubleValue else {
    return nil
}
...
primaryResetsAt: Date(timeIntervalSince1970: primaryResetsAt)
```

**路径 1 触发时，`usedFraction` 和 `resetAt` 都是 OpenAI 服务端真值。** 没有数学，没有外推，没有猜测。

### 路径 2 —— 估算（fallback）

只有路径 1 返回 nil 才走这里。来源：

- `usedFraction` = `已过时间 / 5h`（time-based proxy）
- `resetAt` = `sessionStart + 5h`
- `sessionStart` 本身是从 **rollout 文件名**（`rollout-2026-06-21T17-30-12-<uuid>.jsonl`）里解析出来的，**不**来自任何服务端确认过的窗口起点

代码（`CodexReader.swift:189-200`）：

```swift
private func makeTimeBasedSnapshot(sessionStart: Date, now: Date) -> UsageSnapshot {
    let total = Self.sessionWindow                            // 5h
    let elapsed = max(0, min(total, now.timeIntervalSince(sessionStart)))
    let fraction = elapsed / total                            // proxy %
    return UsageSnapshot(
        ...
        usedFraction: fraction,
        resetAt: sessionStart.addingTimeInterval(total)       // proxy reset
    )
}
```

这条路径**假设** token 消耗随墙钟时间线性增长。这个假设是错的：实际使用可以低 10×（空闲会话）或高 10×（密集多 tool 调用消息）。这里的 `resetAt` 是文件创建时间 + 5h，**和 OpenAI 真实窗口边界没有任何保证一致**。

---

## 路径 2 实际什么时候触发？

`makeSnapshotFromRateLimits`（`CodexReader.swift:208-236`）按文件名时间倒序扫描**最近 5 个** rollout 文件，遇到任意一个含 `payload.rate_limits` 的文件就返回。**没有时间上限** —— 哪怕最近一个文件是 6 个月前的，只要里面有 `rate_limits`，函数就会取它。

所以路径 2 触发要同时满足**所有**条件：

1. `~/.codex/` 存在（目录探测成功）
2. `~/.codex/auth.json` 存在且非空
3. `~/.codex/sessions/` 至少有一个 rollout JSONL，且文件名时间戳在最近 5 小时内（这样 fallback 的 `sessionStart` 才非 nil）
4. 最近 5 个 rollout 文件（按文件名时间）里**没有任何一行**包含 `payload.rate_limits`

条件 4 是稀有的那个。Codex CLI 每次服务端响应都写 `rate_limits`。唯一不写的可能：

- 用户刚启动 codex CLI，第一个响应还没回来就退出了
- rollout 文件被损坏或截断
- Codex CLI 改了 JSON 结构（那就需要代码侧也跟进改了）

**对于任何正常使用的账号，路径 1 都赢。**

---

## 新鲜度问题（真正的关注点）

路径 1 给真值，但给的是 **"上一次 codex CLI 跑那一刻的真值"**。Rollout JSONL 是按事件 write-once 的，没有任何 daemon 在更新它。如果用户中午跑了 codex CLI 然后关了终端，那个中午冻结的文件就是 cuwatch 能看到的最新文件，**永远不会更新**，直到用户下一次跑 codex。

具体时间线：

| 时间 | 发生了什么 | cuwatch 的 Codex 行显示 |
|------|-----------|------------------------|
| 10:00 | 跑 codex CLI，服务端报 30% | 30%，15:00 重置 |
| 11:00 | 空闲（不用 CLI 也不用 Codex.app） | 30%，15:00 重置 |
| 11:00 → 13:00 | 用 Codex.app 桌面密集干 2 小时 | **还是 30%，15:00 重置**（错） |
| 13:30 | 再跑 codex CLI，服务端报 75% | 75%，15:00 重置 |

第 3 行是失效模式：真实的 Codex.app 活动把使用率推到了（比如）70%，但 cuwatch 显示 30%，因为这段窗口里没有任何 rollout JSONL 被写入。

README 是这么坦诚说明的：

> **Codex** | `payload.rate_limits.primary.used_percent` from
> `~/.codex/sessions/**/rollout-*.jsonl` | **Stale snapshot.** Real
> numbers from OpenAI, but only refreshed when `codex` CLI runs.
> Desktop-only users will see hours-to-weeks-old data.

---

## 诚实的表述

对用户描述 Codex 行最诚实的说法：

> 显示的百分比是 **OpenAI 为你账号算出的真实值**，截止时间是你 **上一次跑 codex CLI 的那一刻**。如果你之后一直在用 Codex.app 桌面客户端，这个数字**不**反映那部分活动。

不是"估算"，不是"猜的" —— 但也不是"实时"。

---

## 这对 plan A 意味着什么

之前讨论的 plan A（用 `~/.codex/state_5.sqlite::threads.tokens_used` 补上 desktop-only 盲区）的动机正是这个新鲜度缺口：

- 路径 1 给的是**正确的百分比**但是**错误的时间点**。
- `state_5.sqlite` 给的是**正确的时间点**（CLI 和 Codex.app 都实时写入）但是**错误的单位**（绝对 token 数，不是百分比）。

两个数据源是**互补**而非替代关系：

| 数据源 | 数字 | 新鲜度 | 单位 | 能驱动 dial 吗 |
|--------|------|--------|------|---------------|
| `rate_limits`（JSONL） | 服务端真实 % | 冻结在上次 CLI 跑的时刻 | quota 的 % | ✅ |
| `state_5.sqlite::tokens_used` | 每个 thread 写入的 token 数 | 实时（CLI + Codex.app） | 绝对 token 数 | ❌（没分母） |

组合两者的三个子方案（从之前讨论里摘出来）：

- **A1** —— dial 还是用 `rate_limits` %，但 SQLite 的增量在 CLI 过时时用来外推 %（复杂，但 desktop 用户也能看到 dial 动）
- **A2** —— dial 还是用 `rate_limits` %，popover 里加一个独立的"本机统计"区域，数据来自 SQLite（简单，且对范围差异诚实）
- **A3** —— 抛弃 `rate_limits`，dial 全用 SQLite + 写死 plan-tier 限额（丢掉唯一权威的 quota 数字，没比 ccusage 多出任何优势）

A2 是当前的推荐方向，待 DESIGN.md 兼容性检查（在 dial 下面加个独立读数区域是否符合"单一仪表盘"的 wedge）。

---

## 引用

- `Sources/CuwatchCore/Services/Codex/CodexReader.swift` —— 两条路径
- `Tests/CuwatchCoreTests/CodexReaderTests.swift` —— 覆盖测试，含
  `testFallsBackToTimeProxyWhenRateLimitsAbsent`（验证路径 2）
- `Tests/CuwatchCoreTests/CodexReaderCacheTests.swift` —— cache 层
- [`README.md`](../README.md) §"What works today" —— 准确度对照表
- [`docs/popover-deadlock-fix-plan.md`](./popover-deadlock-fix-plan.md)
  —— 同一个 reader 上的并发 + cache 改动

---

**最后更新**：2026-06-25（初稿，源自 plan A 数据来源的讨论）
