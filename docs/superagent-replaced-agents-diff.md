# 新链路下被 SuperAgent 替代的 Agent 差异对比

> 背景：捕获流程从「submit_input 异步管道（多个专用 agent）」迁移到「SuperAgent 对话入口」后，原管道里的各 agent 有的被吸收成 SuperAgent 的 skill、有的仍独立但触发与数据变了、有的彻底成为孤儿（订阅删除、不再自动触发）。本文逐个对比 system prompt 变化引起的行为差异，以及 user_message 的差异。
>
> 注：card/pkm 两份 prompt 系逐字核对；schedule/comment/clarification/analyze 部分基于探索期排查，结论是结构性的，真正动代码前建议再核对对应 prompt 常量。

## 分类总览

| 命运 | agent | 新归宿 |
|---|---|---|
| **A. 被吸收成 SuperAgent 的 skill** | card_agent | super_agent + manage_timeline_card |
| | pkm_agent | super_agent + manage_pkm |
| | schedule_aggregator_agent | super_agent + schedule_aggregation skill |
| **B. 仍独立，但触发/数据变了** | comment_agent | 独立，由 save_timeline_card 重发事件触发 |
| **C. 彻底成孤儿（订阅删除，不再自动触发）** | analyze_assets | 无；视觉理解并入 super_agent |
| | post_card_router_agent | 无；路由决策消失 |
| | ask_clarification_agent | 无；改为 super_agent 对话里直接问 |

---

## 横切维度对比：运行配置 / 时间语义 / 地点语义

旧管道里的每个专用 agent 都是「单次运行、跑完删 state」的任务执行器；SuperAgent 是「长驻多轮对话」。这带来三个贯穿所有 agent 的维度差异。

### 运行配置

| 维度 | 旧专用 agent（card/pkm/schedule/comment/clarification/post_card_router 一致） | 新 SuperAgent |
|---|---|---|
| `disableSubAgents` | `true` | `true` |
| `planMode` | `PlanMode.none`（不规划，直接执行单任务） | `PlanMode.none`（不规划；曾短暂为 `auto`，已统一回 `none`） |
| `withGeneralPrinciples` | `true` | `true` |
| 上下文压缩 | `LLMBasedContextCompressor`（按 agent 设阈值，单次任务一般压不到） | `SuperAgentContextCompressor`（64k，含 episodic 图片字节剥离） |
| 轮次控制 | 无（任务型，外层重试循环兜底） | loop budget：≥6 轮注入收尾提醒、≥10 轮清空 tools 强制收尾 |
| 生命周期 | 跑完即删 state（comment/clarification/schedule） | 会话级长驻，state 持续保存、可重连 |

**含义**：旧 agent 是确定性的单任务，靠外层重试循环硬保证「重试到完成」；SuperAgent 虽同为 `PlanMode.none`，但它是跨轮累积上下文、会被 loop budget 打断的对话体，没有外层完成校验。同一个 skill 在 SuperAgent 里被调用时，是否执行、是否跑完取决于对话判断，不再有硬保证。

### 时间语义（关键差异）

| | 旧链路 | 新链路 |
|---|---|---|
| 时间来源 | 事件 payload 的 `created_at_ts`（**捕获时刻**），经 `formatLocalDateTimeWithZone` 落成 `Published time` / `Published Time` / `Entry Local Time` | ✅ 已改：折叠进 user message 头部的**单个** `<system-reminder>` 块，含两条独立时间：`User Message Time`（消息发出时刻，重处理时保持原值）+ `Current Local Time`（`DateTime.now()`，重处理时变"现在"） |
| 语义 | 区分「内容发生时间」与「当前时间」（comment 同时有 `Current Local Time` 和 `Entry Local Time` 两个） | ✅ 已改：保留两个时间锚点（User Message Time vs Current Local Time），为将来重处理旧消息保留语义区分 |
| 新建捕获 | — | 对话时刻 ≈ 捕获时刻，基本等价 |
| 编辑旧卡 | — | 对话时刻 = 现在，**不再是该卡原始内容时间**，可能误导 |
| card_agent 特有 | user_message 有 `Published time ... - Do not display the date information on the card` | ✅ 已修复：该「不要在卡上显示日期」约束已加回 `timelineCardSkillSystemPrompt` 的 Workflow 段 |
| comment_agent 特有 | `Entry Local Time` 由 Facts 文件 datetime 解析得到 | ✅ 已修复：改用 `cardData.timestamp`（卡片自带创建/内容时间），不再是 "Unknown" |

### 地点语义

| | 旧链路 | 新链路 |
|---|---|---|
| 计算时机 | submit_input 在**捕获时**算好 `location_context_reminder`，放进事件 payload | LocationContextService 在**对话时**计算 |
| 落位 | 内嵌 `<system-reminder>` 进 `Raw Input Content`（card/pkm），或随 payload 传入（comment/router） | ✅ 已改：与时间/scene/attachment/refs 一起折叠进 user message 头部的**单个** `<system-reminder>` 块（不再是每条信息各包一个标签的独立 systemReminder） |
| card_skill | 旧：location 在 raw input 内；新：卡片改为有 `address` / `user_mark_address` 字段，由 super_agent 按规则判断填写 | — |
| comment_agent | submit_input 传真实 location | ✅ 已修复：`processAICommentReply` 在传入 location 为空时用 card 地点兜底（`userFixedAddress` → `address`，格式化为 `Recorded location: …`）。语义为「记录发生地点」，比设备当前位置更贴合评论场景 |
| 自动地理编码 | analyze_assets 做 GPS 反向地理编码补充地点 | ✅ 已补回（图片）：`_prepareChatImage` 复刻旧逻辑，读原图 EXIF → GPS 反向地理编码 → 拍摄时间/坐标/地址，挂到附件上下文。OCR 仍未恢复 |

---

## A 类：agent → SuperAgent + skill

### 共性：system prompt 结构变化

- **旧**：极小的专用 `xxxAgentSystemPrompt`（单一目标）+ 单个 skill prompt + **外层强制完成校验**（重试循环 + `inspectXxxRunCompletion`）。结构上**保证任务必然执行且跑完**。
- **新**：庞大的 `superAgentSystemPrompt`（记录/查询/编辑/配置多目标）+ 该 skill 与其余 5 个 skill **并列在场** + 无任何强制完成机制，只有 loop budget 收尾。

### 共性行为差异

1. **「必然执行」→「看 SuperAgent 判断」**：旧链路是事件自动触发 + 完成校验硬保证；新链路全靠 SuperAgent 在对话里决定要不要进这个 skill，可能漏做或误判意图。
2. **多 skill 争注意力**：专用 prompt 的纪律（模板选择 / PARA 规则）被稀释在大量其他指令中，严格度可能下降。

### card_agent 特有

- ~~**stale 指令**：card_skill prompt 写「asset 分析结果已提供给你」「assets 引用为 `fs://`」~~ → ✅ 已修复：改为「你能直接感知附件（如能看到附图）」，并把 Workflow 第 1 步的 "asset analysis" 改为 "attached assets"，不再暗示有独立分析步骤。
- ~~**丢失约束**：旧 user_message 里「Published time … 不要在卡上显示日期」随 user_message 消失~~ → ✅ 已修复：在 `timelineCardSkillSystemPrompt` Workflow 段加回「Do not display date or time information on the card itself」约束。
- **fact_id 来源已变**：旧链路由 submit_input 先写 Facts 文件、提前生成 fact_id 传给 agent；新链路 `save_timeline_card` 的 `fact_id` 改为**可选**——新建卡省略则由 `FileSystemService.allocateCardFactId` 系统铸造（扫 Cards 目录取 max+1、锁内写占位卡防撞），并在工具结果返回该 id 供后续写 PKM 复用；传 id 则视为编辑已有卡。模型永不自己编 id。
- **user_message 差异**：
  - 旧 = 单一目的（`User has published new content, 帮用户建卡` + factId + publishTime + factContent，预注入 `get_card_metadata` 结果）。
  - 新 = 对话轮（合并的单个 `<system-reminder>` 块含时间×2/location/scene/attachment/refs + 用户原文 + 内联图片 ImagePart；附件以 `![image](fs://x)` + EXIF 信息列出；模板目录按需调 `get_card_metadata` 拉取）。
  - 原文来源从 Facts 文件变成 SuperAgent 自己产出并写进 `fact` / `assets` 字段。

### pkm_agent 特有（退化最严重）

- **PKM 组织从「每条必做」退化为「可能不做」**：旧 `pkm_agent_task` 订阅每条输入必触发 + 强制「写 PARA 文件 **且** 调 `update_timeline_card_insight`」才算完成。订阅已删，新链路只能靠 SuperAgent 在对话里主动调，而它的 Direct Entry 准则倾向「低风险继续」，**不会对每条捕获都组织 PKM**。
- **连带：card insight 不再自动生成**（insight 正是 pkm_skill 的 `update_timeline_card_insight` 产物）——这也是 comment_agent「Initial Insight 块消失」的根因。
- **丢失 readTool 增强**：旧 pkm_agent 定制 readTool 会注入「文件过长 / 碎片化 / 同名文件频繁编辑 → 建议改名拆分」等 system reminder（防 PKM 结构腐化）；SuperAgent 用通用 file tools，**这些结构健康提醒全部消失**。
- **丢失串行保证**：旧 pkm task 串行执行；新链路靠单会话串行对话兜底。
- **user_message 差异**：
  - 旧 = 预注入完整 P.A.R.A. 目录树（pkmOverview）+ 语言 reminder + 强指令 `instruction`（含 contentText + assetInfo）。
  - 新 = PKM 概览改为按需调 `get_pkm_overview`，无强指令，无 analysis sidecar。

### schedule_aggregator 特有

- **丢失 `stopAfterSetPresentation`**：旧独立 agent 用 `stopAfterSetPresentation=true`，排版一次即停；接进 SuperAgent 时未带此参数，**一轮内可能反复 `set_presentation`**。
- **run context 从 push 变 pull（数据未丢失）**：旧 agent 把完整 schedule_state JSON **预注入**进 user_message（三段式：时间 reminder + run context + 「Please handle the current task」）。SuperAgent 不再预注入，但 schedule_state **仍可获取**——skill 暴露了 `get_schedule_state` 工具（completed 截断最近 20 条 + `completed_truncated`，更早走 `search_completed`）。差异是 push→pull：SuperAgent 需主动调工具拉取，而非开箱即得。
  - execution policy 引导仍在：`scheduleAggregatorSkillPrompt` 保留「pending is the source of truth」「no hallucination」「Preserve pending IDs exactly」等。
  - ⚠️ **stale 措辞**：该 skill prompt 多处写「the **injected** schedule_state from the run context」——「injected/run context」假设只在旧独立 agent（预注入）成立；SuperAgent 下 schedule_state 要靠 `get_schedule_state` 拉取，措辞会误导。待修。
- **自动触发消失**：旧 schedule_aggregator 由 post_card_router 决定后经 `scheduleAggregationRequested` 触发。post_card_router 已成孤儿（C 类），**捕获后不再自动聚合日程**，只能用户 / SuperAgent 在对话里做。
- 保留：「Magazine Bar」质量标准仍在 skill prompt 里。

---

## B 类：comment_agent（system prompt 未变，变的是数据与触发）

**system prompt 完全没改** → prompt 本身不引起行为差异。差异全在 user_message 的**数据源退化**和**触发时序**：

| 模板块 | 旧（submit_input） | 新（save_timeline_card 重发） | 影响 |
|---|---|---|---|
| `<user_raw_input>`（rawInputContent） | Facts 逐字原文（含 fs:// 标记） | ✅ 已改：`card.fact`（AI 转写，含图片内容描述的纯文本）；`processAICommentReply` 已移除 `extractFactContentFromFile`，原文兜底改取 `card.fact` | 非逐字原文，但视觉信息内联进来了 |
| `assetInfo`（formatAssetAnalysis） | 读 `.analysis.txt` 拼带 EXIF 的结构化图片分析 | ✅ 已移除：不再读 `.analysis.txt`，这段 enrichment 已删（含 `agent_utils` import） | 独立结构化图片分析块消失（视觉信息已并入 card.fact） |
| `## Initial Insight`（cardData.insight?.text） | pkm_agent 先跑写了 insight → 有值 | pkm 不在链路 → 基本为空 → 块被省略 | Initial Insight 块消失（根因：自动 PKM 已决定不重建，见「决策已定 1」） |
| `Entry Local Time`（factContent?.datetime） | Facts 解析出条目时间 | ✅ 已修复：改用 `cardData.timestamp`，不再 "Unknown" | — |
| `<related_knowledge>`（PKM context） | pkm 刚组织过，搜索命中新鲜 | PKM 不再组织，命中陈旧 / 空 | 知识库上下文变弱（根因：自动 PKM 已决定不重建，见「决策已定 1」） |
| location（system-reminder 内） | submit_input 传真实 location | ✅ 已修复：传入 location 为空时取 card 地点（`userFixedAddress` → `address`）兜底 | 已解决（语义改为「记录发生地点」） |

**触发时序**：旧 `dependsOn: pkm_agent`（等整条管道跑完）；新无依赖，save_timeline_card 一存完立即触发。

---

## C 类：孤儿（被 SuperAgent「顶替」但能力实际丢失）

这三个最该警惕——不是「换了个 skill 实现」，而是**能力直接消失或降级**。

### analyze_assets → SuperAgent 自己看图

- **丢失能力**：旧 analyze_assets 对每张图做 EXIF 提取（拍摄时间）、GPS 反向地理编码 → address、on-device OCR（`.ocr.txt`，可被 FTS 搜索）、持久化分析文件。
- ✅ **EXIF/GPS 已补回（图片）**：`chat_service._prepareChatImage` 复刻旧逻辑——读存储原图 EXIF（裸字节 copy，EXIF 完整保留）→ 拍摄时间 + GPS 坐标 + `GeocodingService.reverseGeocode` 地址 + `getNearestUserLocation` 比对，挂到 `_buildAttachmentContext` 对应附件条目下。SuperAgent 也用自身视觉把图片内容写进 `card.fact`。
- ❌ **OCR 已决定不要**：on-device OCR（`.ocr.txt` 入 FTS）不恢复（见「决策已定 2」）。`card.fact` 已含图片内容描述。

### post_card_router_agent → 无

- 旧：LLM 决定要不要触发 schedule_aggregator / ask_clarification。
- 新：**整个路由决策层消失**，这些下游不再被自动激活，全压给 SuperAgent 在对话里自行判断。

### ask_clarification（skill 从 SuperAgent 移除 + agent 成孤儿）→ SuperAgent 直接问

- **丢失整套结构化澄清系统**：一键 confirm / choice 卡片、`dedupe_key` 去重、`evidence_fact_ids`、`proposed_memory` → 经 `clarification_resolution_agent` 沉淀进长期记忆、生成 timeline 澄清卡。
- 新：SuperAgent 在对话里随口问。**自由文本，不去重、不沉淀记忆、不建澄清卡**。`clarification_resolution_agent` 订阅虽在，但上游不再产生澄清，等于空转。

---

## 总结

- **A 类**：从「专用 agent + 强制完成校验」降级为「通用对话 agent 的可选 skill」——**最大代价是失去「必然执行」保证**。card_agent 的 stale 指令 / 丢失约束 / fact_id 来源已修复。
- **B 类**：prompt 没变；数据源退化中，Entry time、原文来源、asset enrichment、location 均已改用 card 字段，无遗留待修。
- **C 类**：能力部分丢失——analyze_assets 的 EXIF/GPS 已补回（图片侧），OCR 已决定不要；结构化澄清已决定砍掉；自动路由随之废弃。
- **用户记忆**：自动累积已恢复（新触发点 = `save_timeline_card` 新建卡 → `enqueueFact` → MemoryAgent 批处理）；SuperAgent 的记忆**写**能力从常驻改为按需 `manage_memory` skill，**读**（user_memory reminder）始终在。

## 决策已定（不再重建 / 已接受现状）

1. ~~**自动 PKM 组织 + card insight 生成**~~：❌ 不重建。由 SuperAgent 在对话里按流程判断该不该组织 PKM / 写 insight，不做自动下游触发。
2. ~~**OCR 入索引**~~：❌ 不要。`card.fact` 已含图片内容描述足够，OCR 用户未必想要。图片 EXIF/GPS 已补回。
3. ~~**结构化澄清**~~：❌ 砍掉。接受 SuperAgent 在对话里自由问答，不恢复一键澄清卡 + 记忆沉淀。
4. ~~**schedule 自动聚合**~~：❌ 不重建。由 SuperAgent 在对话里决定是否更新 schedule_state。
5. ~~**comment location 回归**~~：✅ 已修复——设备 location 缺失时取 card 地点兜底。

## 待决策点（B 类，能力要保留）—— 已通过 harness 实现

- ~~**完成校验（"必然执行"保证）**~~：✅ 以"强引导非强制"形态落地。dart_agent_core 新增 turn-completion hook，SuperAgentHarness 在本轮存了新卡却未组织 PKM 时注入**一次**温和提醒（`SuperAgentHarness.buildTurnCompletionHook`）。普通对话轮零触发，不打断聊天。卡片自身完整性（title/ui_configs/status）由 `save_timeline_card` executable 强制。说明：SuperAgent 是交互式对话，刻意不做旧式"硬重试到完成"——符合"SuperAgent 自己判断"基调。
- ~~**pkm readTool 动态提醒**~~：✅ 已恢复。改用 dart_agent_core 的 post-tool hook：读 `/PKM` 文件时复刻旧 pkm_agent 的结构健康检查（行数 >1000/2000、目录碎片化、日期文件名、最近 5 次频繁编辑），作为提醒注入下一轮（`SuperAgentHarness._buildPkmHealthReminder`）。只对 PKM 读触发。

## 剩余 prompt 优化点 —— 已全部处理（Phase 1）

- ~~**完整捕获流程编排缺失**~~：✅ 已加。superAgentSystemPrompt 新增"Capturing a Record"段（可选找卡 → 可选设计模板 → 必建/更新卡拿 fact_id → 推荐写 PKM 用该 fact_id 关联 → 可选 schedule），明确强引导非强制。
- ~~**fact_id 跨工具传递**~~：✅ 已加。system prompt 新增"fact_id — the identity of a record"段（来源/含义/用途）；`save_timeline_card` 工具结果明确标注 fact_id 并示范 `<!-- fact_id: … -->` 写法。
- ~~**schedule / pkm skill 的 stale 措辞**~~：✅ 已清。"injected from run context" → "调 get_schedule_state / get_pkm_overview 获取"；pkm/card 的"分析已提供给你" → "你能直接感知附件"；dynamic_timeline_ui 循环依赖措辞 → "建卡流程的子步骤"。

## Harness 工程（Phase 2 + 3，本轮新增）

- **dart_agent_core 扩展**（`/Users/ming/Downloads/project/opensource/memex-second/dart_agent_core`，pubspec path override 接入）：参考 codex 新增三个向后兼容 hook —— turn-completion（模型无工具调用时可注入 follow-up 续跑，带 maxTurnContinuations 预算）、pre-tool、post-tool。null = 原行为。
- **SuperAgentHarness**（`lib/agent/super_agent/super_agent_harness.dart`）：用 post-tool hook 做 PKM 健康提醒 + 追踪本轮捕获进度；用 turn-completion hook 做一次性 PKM 组织 nudge。
- **工具层加固**：`update_timeline_card_insight` 改为校验**卡片**存在（不再读已废弃的 Facts 文件）、关掉 createIfNotExists（杜绝幽灵卡）、related_fact_ids 做真实卡存在性过滤；`save_timeline_card` 的 assets 做 fs:// 文件存在性校验，丢弃编造引用。
- **明确不做**：workflow-aware 工具可见性路由（SuperAgent 单一入口，一轮 workflow 无法在调用前干净确定，强行隐藏反伤灵活性）；set_presentation 一轮一次（那是旧独立 agent 减少调用的优化，SuperAgent 不需要）。
