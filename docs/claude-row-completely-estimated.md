# Claude 行：现在的做法完全没有依据

**状态**：说明性文档 —— 记录当前的实现是猜的，不是真值
**撰写**：2026-06-26 office-hours 讨论时被用户抠出来这个问题
**姊妹文档**：
- [`docs/claude-statusline-rate-limits.md`](./claude-statusline-rate-limits.md)（脱离猜测的唯一已知路径）
- [`docs/codex-row-real-vs-estimated.md`](./codex-row-real-vs-estimated.md)（Codex 是真值 + stale 的对比参照）
- [`README.md`](../README.md) §"What works today"（准确度对照表 —— 但 reset 时间没标"估算"是漏洞，本文档结尾会指出）

---

## 一句话总结

**cuwatch 的 Claude 行现在显示的 `used %` 和 `resetAt` 两个字段，都是基于一个无法证明的假设算出来的。"verified 2026-06-21" 那条记录验证的是另一件事，不是这件事。准确说法：两个字段都是猜的。**

---

## 背景：office-hours 抠出来的逻辑漏洞

2026-06-26 用户问 "现在 Claude Code 的进度和重置时间是估算的吗？" 我一开始的回答框架是：

| 字段 | 我说的 |
|------|--------|
| `usedFraction` | 估算（时间代理）|
| `resetAt` | **"精确到秒，半推算" / "计算式准确"** |

用户**反复抠这个区分**，最终问出了关键的反例：

> "claude 就是在 10 点重置，或者 10 点 05 分重置，我是 9 点 50 说的话，那你怎么推算都没有依据啊"

这一刀把整个论证砍倒。下面解释为什么。

---

## 现在的算法

`Sources/CuwatchCore/Services/Claude/ClaudeReader.swift`。

### Session 检测（line 184-215）

```swift
1. 把 ~/.claude/projects/**/*.jsonl 里所有 assistant message
   的 timestamp 收齐，按升序排
2. windowStart = sorted[0].timestamp
3. for record in sorted.dropFirst():
       windowEnd = windowStart + 5h
       if record.timestamp >= windowEnd:
           windowStart = record.timestamp   // 这条消息开了新窗口
4. 返回最后一个 windowStart 作为"当前窗口起点"
```

### 进度和重置计算（line 217-234）

```swift
elapsed = now - session.start              // 已经过去多久
elapsed = clamp(elapsed, 0, 5h)            // 不超过 5h
usedFraction = elapsed / 5h                // 这就是进度数字
resetAt = session.start + 5h               // 这就是重置时间
```

`5h` 是常量：`ClaudeReader.swift:27` 的 `5 * 60 * 60`。

---

## 算法依赖的假设（这是没依据的部分）

整个算法在做三件事，每件都依赖一个**无法证明的假设**：

| 计算 | 假设 | 是否能验证 |
|------|------|-----------|
| `session.start = first_message_timestamp` | Anthropic 服务端的 5h 窗口起点等于你 JSONL 里第一条 assistant message 的时间戳 | **无法验证**。JSONL 里没有"服务端窗口起点"字段。客户端时间戳和服务端 billing 起点之间可以差几秒、几分钟、甚至更多 |
| `5h = 5 * 60 * 60` 这个常量 | Anthropic 没改过文档化的 5h 窗口长度 | 可文档化验证（Anthropic 文档），但实时验证不到 —— 偷偷改了我们不会知道 |
| `usedFraction = elapsed / 5h` | token 消耗随时间线性增长 | **明显错的**。空闲会话用得少，密集多工具调用用得多。同样 elapsed 60% 可能对应真实 5% 或 95% |

第一项是最致命的。

---

## 用户给的反例 —— 完全击穿 session.start 假设

假设 Anthropic 的服务端 5h 窗口是 **clock-aligned**（按固定时钟对齐），比如每天 5:00 / 10:00 / 15:00 / 20:00 重置一次。

具体场景：

- **真实情况**：Anthropic 的窗口 5:00 开，10:00 重置
- **你的行为**：9:50 第一次跟 Claude 说话
- **cuwatch 的算法**：看到 9:50 是 first message → 假设 windowStart = 9:50 → 预测 resetAt = 14:50
- **实际 resetAt**：10:00（你完全不知道窗口已经跑了 4h 50min）

后果：
- 9:50 → 10:00 这 10 分钟：cuwatch 显示"刚开始 3%"，实际**马上要 reset**
- 10:00 那一刻：Anthropic 真的 reset 了 —— 你的 quota 满血回血
- 10:00 之后：cuwatch 还以为窗口在 9:50 开始，于是 14:50 才会 "reset"。整个新窗口的 5h 里 cuwatch 全部显示错的剩余时间

**误差不是几秒，是 4 小时 50 分钟**。这才是用户抠的真东西。

---

## "verified 2026-06-21" 验证了什么 / 没验证什么

`ClaudeReader.swift:187-201` 的注释：

> Earlier algorithm (broken): walked backward and absorbed any event within 5h of a moving session start. That treated "I used Claude this morning, then again 3h later this afternoon" as ONE 5h session anchored to the morning, blowing usedFraction up to 91% when the real fixed-window-from-afternoon-first-message was at 20-40%.

**这条注释验证了的事**：
- ✅ Anthropic 的窗口是 **fixed window**（窗口起点不会被后续 message 拉走），不是 sliding window
- ✅ 窗口长度大约是 5h（用户当时看 20-40% 范围合理）

**这条注释 NO **没验证**的事：
- ❌ "fixed-window-from-afternoon-first-message" 这个**起点对齐**究竟是 `afternoon-first-message` 还是 `afternoon-clock-aligned-anchor`
- ❌ 客户端时间戳和服务端 billing 起点之间是否完全一致
- ❌ 是否存在 server-side 排队 / 缓存导致窗口起点延迟

也就是说 **"fixed-window" 的形状被验证了，但"起点 = 第一条消息时间戳" 这一步是裸假设**。我把"形状对" 当成了"起点对" 用，逻辑上跳了一步。

---

## 实际后果矩阵

| Anthropic 真实窗口模型 | cuwatch 算出的 resetAt | 误差 |
|------------------------|----------------------|------|
| 起点 = 你第一条 message 时刻（我的假设） | 准 | 0 |
| 起点 = clock-aligned（每 5h 整点） | 错 | 可达 4h 59min |
| 起点 = 第一个被服务端真正计入 rate limiter 的请求时刻（可能比 first message 晚几秒） | 略错 | 几秒到几分钟 |
| 起点 = 一天内的首次活动按某种 server-side 算法计算 | 错 | 取决于算法 |

**我们没办法区分这四种**。任何客户端推断都建立在"我们看到的 JSONL 时间戳 = Anthropic billing 起点" 这一裸假设上，**这个假设没有任何独立证据**。

---

## 不能用 ccusage / 其他工具的存在作为依据

社区里 [ccusage](https://github.com/ryoppippi/ccusage) 等 Claude 用量工具也用类似的"first message + 5h" 启发式。**这不能证明这种做法对** —— 可能整个生态都在错，只是误差不够大让人发现，或者 Anthropic 的实际算法接近"per-user 起点窗口"，但都不是验证。

---

## 唯一能脱离猜测的路径

`docs/claude-statusline-rate-limits.md` 里写过：Claude Code v1.2.80+ 通过 statusline JSON channel 把真值用 stdin pipe 给注册的脚本：

```json
{
  "rate_limits": {
    "five_hour": {
      "used_percentage": 38.2,
      "resets_at": "2026-06-26T15:30:00Z"
    }
  }
}
```

- `used_percentage` 是 **Anthropic 服务端算的真实 token 用量**（不是时间代理）
- `resets_at` 是 **Anthropic 服务端给的真实重置时刻 ISO 时间戳**（不是 first message + 5h）

性质和 Codex 的 `payload.rate_limits.primary.{used_percent, resets_at}` 完全一样 —— 是真值，不是猜的。

**cuwatch 没实施 statusline 路径**。所以现在 Claude 行的两个字段都还在猜。

---

## 诚实标签的最终版本

之前 README 和我口头上的标签都不准确。准确版本：

| 字段 | 现状 | 是否猜的 |
|------|------|--------|
| Claude 行的 `usedFraction` | `elapsed / 5h` 时间代理 | **完全猜的** —— 时间代理本身就是估算，且 elapsed 的起点 = first message 也是猜的 |
| Claude 行的 `resetAt` | `first_message_timestamp + 5h` | **完全猜的** —— 起点是猜的，5h 长度也是写死的假设 |
| Claude 行的 `session.start` | 从 JSONL 读 first message timestamp | 文件层面是真的，但**作为服务端窗口起点是猜的** |
| Claude 行的"是不是有活跃 session" | `now <= session.start + 5h` 检查 | 半猜 —— "有活动 = 有 session" 算是 OK，但具体 session 边界还是猜的 |

跟 Codex 行的对比：

| 字段 | Codex | Claude |
|------|-------|--------|
| usedFraction | 真值（OpenAI 服务端算的，stale）| **猜的**（时间代理 × 猜起点）|
| resetAt | 真值（从 `resets_at` Unix epoch 读）| **猜的**（first message + 5h）|

**Codex 行至少有一边是真的（数值真，时间真，但都 stale）。Claude 行两边都是猜的。**

---

## README 的描述漏洞

`README.md` 第 64-67 行：

> **Claude Code Plan** — reads `~/.claude/projects/**/*.jsonl`, detects the
>   active 5h billing window using Anthropic's actual fixed-window semantics
>   (not adjacent-gap heuristics), reports `elapsed / 5h` as used %.
>   Accurate session WINDOW; inaccurate usage WITHIN the window.

"Accurate session WINDOW" 这句是**错的**。session WINDOW 的起点本身就是猜的，整个窗口边界都不一定准。

第 89-95 行的"What doesn't work yet"：

> **Claude row's `used %` is a time proxy, not real token usage.**
> ...

承认了 `used %` 是代理。**但完全没提 `resetAt` 也是猜的**。这是 README 漏掉了一项诚实声明。

**修复建议**（不在本次 commit，留作下一次 README 更新）：
1. 把 "Accurate session WINDOW" 改成 "Inferred session window — start anchored to your first JSONL message timestamp, which assumes (without evidence) that Anthropic's billing window starts at the same moment."
2. 在 "What doesn't work yet" 加一条 "Claude row's `resets in N` is computed from `first_message + 5h`. We have no way to verify this matches Anthropic's actual reset moment. Could be off by minutes or hours."

---

## Non-goals

- **不要试着用更复杂的客户端启发式去拟合服务端窗口**。任何不读真值的做法都还是猜。
- **不要把这条算法宣传成"differs from ccusage / better than ccusage"**。两边算的都是猜，没有"更好"。

## 后续可能议程

1. 实施 statusline 路径（**唯一**真正脱离猜测的方法）
2. 同步更新 README 和 DESIGN.md 的诚实标签
3. 在 Claude 行 UI 上加一个 caveat tooltip：默认 "estimated · install statusline for live data"

---

**Last updated**：2026-06-26（office-hours 用户当面抠出这个逻辑漏洞后写的，记录自己被打脸的过程）
