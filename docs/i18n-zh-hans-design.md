# cuwatch i18n — 简体中文支持设计文档

**状态**：设计已锁定 2026-06-26 office-hours，实施未开始
**Office-hours 决策链**：D1=B / D2=A / D3=A / D4=A
**姊妹文档**：
- [`DESIGN.md`](../DESIGN.md) §"Decisions Log"（v1 English-only 在 2026-06-13 被 plan-design-review D5 写死；本设计撤销）
- [`docs/popover-deadlock-fix-plan.md`](./popover-deadlock-fix-plan.md)（最近 wedge 演化的范本）
- [`docs/codex-logbook-design.md`](./codex-logbook-design.md)（最近 anchor 演化的范本）

---

## 一句话总结

cuwatch v0.1 i18n：bundle Sarasa Mono SC（OFL 1.1）取代 SF Mono，让中英文都 monospaced；外提所有 UI 字符串成 String Catalog；Preferences 加 Language picker（System / English / 简体中文，默认跟系统）；翻译用克制工匠口吻，单位（B / M / %）保留英文，不本地化数字格式。**撤销 2026-06-13 plan-design-review D5 的 "v1 English-only" 决策**。

---

## 背景：为什么现在做

### 用户表态

2026-06-26 office-hours，用户原话：

> "做一下 i18n 的功能 preferences 这里现在里面都是英文的 考虑支持一下中文 我们讨论一下这个功能 必须讨论"

随后："你不用管在哪些渠道去推广，现在需要把中文加上 加上我才能去推广，你不用考虑别的了 现在就考虑如何做好 i18n"。

### 动机（office-hours D1 = B）

选择的动机：**B — 中国开发者群体也用 Claude/Codex/Minimax，他们也该看到中文**。

诚实备忘：动机里有"作者自己也想用中文"（A）的成分，但用户明确选择以 B 作为产品话术。本文档按 B 的范围设计 —— 全 UI 翻译，不是"仅 Preferences"。

### 撤销的决策

`DESIGN.md` Decisions Log 2026-06-13：

> | 2026-06-13 | VoiceOver labels English-only for v1 | Per /plan-design-review D5. 30+ labels enumerated in plan's Accessibility specifications section. Localization deferred to v1.x. Matches existing app-UI English-only decision. |

**本文档撤销此决策**。理由：用户作为作者明确要求中文 UI 作为 distribution prerequisite。"deferred to v1.x" 那个时间点提前到 v0.1。

---

## Wedge 决策（W1-W5）

### W1 — 字体策略：Bundle Sarasa Mono SC

**Office-hours D2 = A（接受 OFL 1.1） + D3 = A（接受 Sarasa Mono SC 气质）**。

#### 字体选择

| 角色 | v1 之前 | v1 之后 |
|------|---------|---------|
| 拉丁 / 数字 | SF Mono (macOS 13+) / Menlo | **Sarasa Mono SC**（Iosevka DNA）|
| 中文 | 自动 fallback PingFang SC | **Sarasa Mono SC**（Source Han Sans DNA）|
| Weights | 400 Regular + 500 Medium | 同上 |

#### 许可证

**SIL Open Font License 1.1**。已验证（GitHub `be5invis/Sarasa-Gothic/LICENSE`）。要求：

1. 在 cuwatch repo 加 `LICENSE-FONTS-OFL-1.1.txt`（OFL 完整文本 + 上游版权）
2. 在 `.app` bundle Resources 里放同一份 OFL 文本
3. README Acknowledgments 加 attribution：
   > Bundles [Sarasa Mono SC](https://github.com/be5invis/Sarasa-Gothic) by Belleve Invis, licensed under [SIL Open Font License 1.1](./LICENSE-FONTS-OFL-1.1.txt).
4. 不改字体内容 → 可保留 "Sarasa Mono SC" 名称
5. cuwatch 自身代码许可证（MIT/Apache 2.0 TBD）**不受 OFL 影响**

#### Bundle 大小

预计增量 **6-10MB**（Regular + SemiBold 两个 TTF）。如果将来 release 体积太大，可做 subsetting 压到 1-2MB（v0.1 不做）。

#### 撤销的决策

`DESIGN.md` Decisions Log 2026-06-21 第 165 行：

> | 2026-06-21 | Typography reversal: IBM Plex Mono (bundled OTF) → system monospaced design font. | ... Accept the small differentiation loss for: zero bundle weight ... |

**本文档撤销 "zero bundle weight" 那条 trade-off**。理由：i18n 中文需要 CJK monospace，bundle 是不可避的代价；同时 Sarasa Mono SC 的工业派气质**比 SF Mono 更贴 "1960s 工坊仪表" wedge**。

---

### W2 — Type scale：不调整

中文版下继续用 DESIGN.md 锁定的 **10 / 11 / 13 / 15 / 22 / 34pt**。

理由：
- Sarasa Mono SC 为屏幕优化（Iosevka + Source Han Sans 都做了 screen hinting）
- DESIGN.md "locked, do not add sizes" 是 wedge，本设计不动
- 如果 10pt CJK 实际渲染糊，是 v0.2 微调话题，不在本设计范围

---

### W3 — Locale detection：混合（默认跟系统 + Preferences picker）

Preferences "Behavior" 段加一行：

```
LANGUAGE                          (xs label uppercase)
[ System ▾ ]                      (system | English | 简体中文)
                                  default = system
```

#### 行为规则

- **默认值**：System（读 `Locale.current.language.languageCode`，匹配 `zh-Hans` → 中文 UI，其他 → 英文 UI）
- **override**：picker 改了立刻生效（SwiftUI `Environment(\.locale)` 注入，不需要重启）
- **持久化**：`UserDefaults.standard.set(...)` 存 "system" / "en" / "zh-Hans" 三种字符串
- **切换路径**：picker 改 → PreferencesViewModel 写 UserDefaults → 通过 Combine pipeline 触发 root environment locale 改变 → 所有 SwiftUI views 重渲染

#### 文案规则

picker label 在英文 mode 显示 "LANGUAGE"，中文 mode 显示 "语言"。picker 选项内部值是 ISO code，显示文本同时本地化。

---

### W4 — 翻译 register：直译 + 工匠克制

#### 词汇基线

参考 macOS Apple 中文系统翻译惯例，避免 SaaS 营销腔。

#### 关键词翻译表（用户已审核 2026-06-26）

| 英文 | 中文 |
|------|------|
| Preferences | 偏好设置 |
| Logbook | 记录簿 |
| Reset | 重置 |
| Window (5h) | 窗口 |
| Cumulative tokens | 累计 Token |
| Peak | 峰值 |
| Streak | 连续天数 |
| Active days | 活跃天数 |
| Quit | 退出 |
| Back | 返回 |
| Updated 12s ago | 12s 前更新 |

#### 风格规则

- **保留 Apple 系统词汇**（"偏好设置" 而非 "设置"；"重置" 而非 "刷新"）
- **不创造新词**（不发明 "用量记录簿"，就用 "记录簿"）
- **保留专业术语英文**（Token、CLI、JSONL 不译；plan tier "plus" / "pro" 不译）
- **不用感叹号 / 不用问号修饰**（工匠克制）
- **句子尽量短**（仪表盘文案应该是 caption，不是 prose）

---

### W5 — 数字 / 单位 / 时间：保留英文，不本地化

| 类型 | 例 | 中英都用 |
|------|----|----------|
| Token 大数 | `5.05B`, `312M`, `78K` | 不本地化（不写 "50.5 亿"）|
| 百分比 | `38%`, `88%` | 同一形式 |
| 时长 | `2h 14m`, `5h window` | 不本地化（不写 "2 小时 14 分钟"）|
| 日期 | `2026-04-24` | ISO 不本地化 |
| 数字单位 | `B`, `M`, `K` | 英文符号 |

#### 理由

- 数字、token、% 是**国际通用工程符号**
- 中文 dev 也习惯看 5.05B / 88% / 2h 14m（看 GitHub、看 ccusage、看 Codex.app 都是这种格式）
- 本地化为 "50.5 亿 / 88% / 2 小时 14 分钟" **破坏仪表感**（Sarasa Mono SC 的 monospace + tabular figures 价值就在这）

---

## Implementation 决策（I1-I5）

### I1 — i18n 技术

**两个 target 用不同方案**：

| Target | 方案 | 文件位置 |
|--------|------|---------|
| `cuwatch` app target（Xcode） | **String Catalog (`.xcstrings`)** | `cuwatch/cuwatch/Localizations/` |
| `CuwatchCore` (SwiftPM) | **传统 `.strings` + `Bundle.module`** | `Sources/CuwatchCore/Resources/<lang>.lproj/Localizable.strings` |

#### 理由

- `.xcstrings` 是现代 Apple 路径（Xcode 15+ 原生编辑器、JSON storage、自动 plural rules）
- SwiftPM library 对 `.xcstrings` 支持有限（Swift 5.9 起部分支持，但 cuwatch v0.1 暂不依赖那个边界）
- `CuwatchCore` 的字符串很少（error reasons、display labels），用传统 `.strings` + `Bundle.module` 稳定

#### 调用方式

```swift
// app target
Text(String(localized: "preferences.title"))

// CuwatchCore
let title = NSLocalizedString("monitor.error.networkTimeout",
                              bundle: .module,
                              comment: "Shown when polling Minimax API times out")
```

---

### I2 — 翻译来源：AI 初稿 + 作者逐条审

工匠 wedge 不允许 AI 译不审。流程：

1. AI（Claude）生成 zh-Hans 初稿（约 200 条字符串）
2. 作者（用户）逐条 review，可以批量改或针对个别字符串改
3. merge 进 `.xcstrings` / `.strings` 文件
4. 任何后续新增字符串都走同一流程

---

### I3 — 字符串组织：按 view 拆

```
cuwatch/cuwatch/Localizations/
├── PreferencesView.xcstrings    (~40 strings)
├── PopoverView.xcstrings        (~30 strings)
├── LogbookView.xcstrings        (~15 strings)
├── Onboarding.xcstrings         (~20 strings — FDA prompt, codex setup hint)
└── Common.xcstrings             (~30 strings — Back, Quit, units, errors)

Sources/CuwatchCore/Resources/
├── en.lproj/Localizable.strings  (~20 strings — error reasons, display labels)
└── zh-Hans.lproj/Localizable.strings
```

#### 理由

- 单文件 200+ 字符串易乱
- 按 view 拆，找的时候直接 → 对应文件
- Common 收纳 cross-view 共享词（Back / Quit / 数字单位 / 错误）

---

### I4 — 复数 / interpolation：不做 stringsdict

- 中文没复数 → 直接 `"\(n) 天"` 即可
- 英文复数用 `String.localizedStringWithFormat` 处理（"1 day" / "N days"），不引入 stringsdict 文件
- 后续若需要严格复数规则，再加 `.stringsdict`

---

### I5 — 切换语言：实时切换（无重启）

```swift
@main
struct CuwatchApp: App {
    @StateObject var preferencesVM = PreferencesViewModel(...)

    var body: some Scene {
        // ...
        WindowGroup {
            PopoverShell(...)
                .environment(\.locale, preferencesVM.effectiveLocale)
        }
    }
}
```

`PreferencesViewModel.effectiveLocale` 是 `@Published`，picker 改了 → SwiftUI environment locale 改 → 所有 view 重绘 → 文本即时切换。

不弹 "restart required"。无 alert。无 modal。无 SaaS 痕迹。

---

## 翻译表（v0.1 完整 zh-Hans）

完整翻译表见 v0.1 实施 PR 的 `.xcstrings` 文件。本文档只锁定 W4 表里的关键词。其他词按 W4 风格规则由作者 review 时定。

---

## DESIGN.md 改动清单

1. **第 32 行**：字体段更新
   - 旧：`Everything: the system monospaced design font (SF Mono on macOS 13+, Menlo on older).`
   - 新：`Everything: bundled Sarasa Mono SC (OFL 1.1). Provides true 1:2 monospace ratio for mixed CJK + Latin without falling back to PingFang SC. Replaces 2026-06-21 SF Mono choice.`

2. **第 33 行 weight set 不变**：Regular (400) + Medium (500)

3. **Decisions Log 加 2026-06-26 两条**：
   - 撤销 2026-06-13 D5 "VoiceOver English-only for v1" / "app-UI English-only"
   - 撤销 2026-06-21 "Typography reversal" 里 "zero bundle weight" 那条 trade-off，bundle 字体回归

4. **第 12 行（Localization Status）**：写明 zh-Hans 是 v0.1 一等公民语言，en 是 fallback

5. **Implementation Notes 加一段** "Font registration"：runtime 用 `CTFontManagerRegisterFontsForURLs` 注册 bundled `.ttf`

---

## 实施 phases

| 阶段 | 范围 | 预估 |
|------|------|------|
| 1 | 下载 Sarasa Mono SC TTF + 写 LICENSE-FONTS-OFL-1.1.txt + Info.plist + decision log | 1h |
| 2 | DESIGN.md 改动（字体段 + decisions log + localization status） | 30min |
| 3 | 创建 `.xcstrings` 5 个文件（en 是 base，添加 zh-Hans translations stubs） | 30min |
| 4 | 把所有 hardcoded 字符串外提成 `String(localized:)` —— PopoverView、PreferencesView、LogbookView、OnboardingView、PopoverShell | 3-4h |
| 5 | AI 生成 zh-Hans 翻译初稿 + 用户逐条 review + merge | 2-3h |
| 6 | Preferences 加 Language picker UI + PreferencesViewModel `effectiveLocale` | 1-2h |
| 7 | SwiftUI Environment locale 注入 + 切换实时生效逻辑 | 1-2h |
| 8 | CuwatchCore 字符串（error reasons / display labels）走 `Bundle.module` `.strings` | 1h |
| 9 | 字体注册 runtime code（`CTFontManagerRegisterFontsForURLs`）+ verify Sarasa Mono SC 在 SwiftUI 里通过 `Font.custom("Sarasa Mono SC", size:)` 可达 | 1h |
| 10 | 测试：英中切换、字体 fallback 验证、layout 不破、所有 view 重绘正确 | 2h |
| 11 | README 更新（Acknowledgments + 中文支持声明）+ commit | 30min |
| | **合计** | **~12-15h（1-2 个工作日）** |

---

## Non-goals

- **不做 zh-Hant（繁体）** —— v0.1 只支持 en + zh-Hans
- **不做其他亚洲语言**（ja / ko）—— v1.x 议程
- **不做欧洲语言** —— 没需求
- **不做数字本地化**（5.05B → 50.5 亿）—— 故意，保留仪表感
- **不做时间本地化**（"2h 14m" → "2 小时 14 分"）—— 故意
- **不做 Logbook 内 disclosure 文本的高级 placeholder 系统**（"Codex.app shows..." 直接两套字符串）
- **不做 Subsetting** —— v0.1 bundle 全字符（6-10MB OK）
- **不做 dynamic 字体加载** —— bundled 字体 launch 时一次性注册

---

## Open questions / 后续可能议程

1. **DESIGN.md "VoiceOver English-only for v1" 怎么改** —— 本设计撤销了 app-UI English-only，VoiceOver labels 也应该跟着撤销。但 VoiceOver 翻译是另一组字符串，本设计不强制 v0.1 做，留作 v0.x
2. **Sarasa Mono SC 真实渲染 10pt CJK 糊不糊** —— Implementation 阶段实际跑出来看，如果糊，可能要 W2 让步（局部调 type scale）
3. **README 翻译要不要也做** —— 本设计只覆盖 app UI；README 翻译是 distribution 工作，留作 separate scope
4. **CuwatchCore 的 error reasons 字符串数量** —— 现在估 ~20 条，实际外提时再 count
5. **Sarasa Mono SC SemiBold 实际 stroke weight 是不是 500** —— Sarasa 的 weight 命名可能是 Regular / Bold 两档，需要 verify 是否需要选 "SemiBold" 还是 "Bold" 对应 DESIGN.md 的 500 Medium。Implementation 阶段验证

---

## 参考

- [Sarasa Gothic GitHub](https://github.com/be5invis/Sarasa-Gothic) — 字体源
- [Sarasa Gothic LICENSE (OFL 1.1)](https://github.com/be5invis/Sarasa-Gothic/blob/master/LICENSE)
- [SIL OFL 1.1 官方文档](https://scripts.sil.org/cms/scripts/page.php?site_id=nrsi&id=OFL)
- [Apple String Catalog 文档](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog)
- [`Sources/CuwatchCore/State/PreferencesViewModel.swift`](../Sources/CuwatchCore/State/PreferencesViewModel.swift) —— 将加 `effectiveLocale` 的 VM
- [`cuwatch/cuwatch/UI/PreferencesView.swift`](../cuwatch/cuwatch/UI/PreferencesView.swift) —— picker 入口位置

---

## Office-hours 决策链

| ID | 问题 | 选择 |
|----|------|------|
| D1 | 目标受众 | **B** — 中国开发者群体也用 Claude/Codex/Minimax |
| D2 | Sarasa Mono SC 的 OFL 1.1 是否接受 | **A** — 接受 |
| D3 | Sarasa Mono SC 字体气质是否合 wedge | **A** — 信任，不预审 sample |
| D4 | 接受完整 i18n 设计包 | **A** — 全盘接受 |

**Status**：DONE — 设计文档已写，等待 implementation 启动

---

**Last updated**：2026-06-26（office-hours 当场设计完成）
