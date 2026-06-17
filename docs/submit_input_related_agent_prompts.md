# submit_input 关联的 Agent prompt 流转（逐字 user_message + 来源标注）

## 一、submit_input 事件出口（唯一入口）

### 事件发布点（逐字）
- `submit_input.submitInput` 在 `lib/data/repositories/submit_input.dart` 中发布：
  - `SystemEventTypes.userInputSubmitted`
  - `payload`：`UserInputSubmittedPayload`

### `UserInputSubmittedPayload` 全量字段（逐字）
- `fact_id`
- `asset_paths`
- `combined_text`
- `markdown_entry`
- `created_at_ts`
- `pkm_created_at_ts`
- `location_context_reminder`

### 触发订阅（`lib/data/repositories/memex_router.dart::_registerEventSubscriptions`）
- `subscriptionId: 'comment_agent'`
- `taskType: 'comment_agent_task'`
- `payloadBuilder` 产出：
  - `fact_id`
  - `combined_text`
  - `created_at_ts`
  - `location_context_reminder`

### 关联补充（同源重发）
- `reprocess_pending_cards.dart` 与 `retry_failed_cards.dart` 会重构同一 `UserInputSubmittedPayload` 再次发布同名事件，走相同订阅链。

---

## 二、comment_agent（submit_input 直接下游）

### 运行配置
- `disableSubAgents: true`
- `planMode: PlanMode.none`
- `withGeneralPrinciples: true`

### system message 来源边界
- 来自 Agent 本体：`lib/agent/comment_agent/prompts.dart`
  - `commentAgentSystemPrompt`
  - 结构（章节逐字，正文省略号）：
    - `You are the runtime for Memex character comments.`
    - `# Role Boundary`
    - `# System Reminder`
- 来自 Skill：`lib/agent/skills/comment_agent/comment_agent_skill.dart::_buildSystemPrompt`
  - `CommentAgentSkill.systemPrompt` = `characterOverride? + Prompts.commentSkillSystemPrompt + 可选的用户资料/角色记忆/风格示例块`
  - `commentPromptOverride` 为最高优先级：`Name/Tags/### Persona` 段落（若有则强制前置）
  - `Prompts.commentSkillSystemPrompt(identity, instruction, forceReply)`（来自 `lib/agent/prompts.dart`）
  - 可选块（逐字标题）：
    - `## User Profile`
    - `## Character Memory Entries`
    - `## Style Examples`
- 额外注入（并非来自 Agent/Skill 的 prompt 常量）：
  - `memoryManagementPrompt`（`MemoryManagement.createDefault(...).buildMemoryManagementPrompt()`）仅在 `withMemoryManagement == true` 时作为独立 `systemPrompts` 元素附加。
  - `state.systemReminders['character_world']`：`## Triggered Character World Entries\n${ctx.characterWorld}`（有角色且命中角色世界时）
  - `state.systemReminders['character_timeline']`：`## Compressed Interaction History\n${ctx.checkpoints}` 与 `## Recent Cross-Scene Interactions\n${ctx.recentTimeline}`（有角色且存在上下文时）
  - `state.systemReminders['user_knowledge_cards']`：`## User Knowledge Cards\n${ctx.knowledgeCards}`（有角色且命中知识卡片时）
  - 无角色时，`userProfile = await memoryManagement.buildMemoryPrompt()`，作为 skill prompt 的 `## User Profile` 内容。

### skill 内变量（完整逐字）
- `identity`（参数名 `identity`）
- `instruction`（传入 `UserStorage.l10n.commentLanguageInstruction`）
- `forceReply`（布尔）
- `character`（是否存在 `systemPromptOverride`，并影响前置段落）
- `userProfile`（可空）
- `characterMemories`（可空）
- `userContent`（最终可变为 `Prompts.commentAgentInitialCommentPrompt`）
- `systemReminder`（动态拼接：当前时间 + 可选 location）
- `factId / entryTime / rawInputContent / initialInsight / existingCommentsContext / forcedReplyToId`

### 路由与上下文补充
- `comment_agent_handler.dart` 会先读取 `CommentSettingsService.load(userId)`：
  - `enableCharacterComment == false` 且没有显式角色路由时，跳过 comment_agent。
  - `maxCommentCharacters <= 1` 时使用 `CharacterSelectionService.selectCharacter(...)` 单角色选择。
  - `maxCommentCharacters > 1` 时使用 `CharacterSelectionService.selectMultipleCharacters(...)` 多角色选择，并按顺序逐个处理，使后续角色能看到已有评论。
- 显式角色路由来源：
  - payload 中的 `character_id`
  - raw input 里的 `@角色id` 或 `@角色名`
  - 显式角色路由会设置 `forceReply = true`。
- `CommentAgent.runWithContent(...)` 会在 `pkmContext` 为空时调用 `_loadPkmContextIfNeeded(...)` 懒加载知识库上下文。
- 有 `characterId` 且 `rawInputContent` 非空时，会写入角色 timeline event：`scene: CharacterMemoryScene.comment`、`type: CharacterMemoryEventType.postObserved`。

### 工具与完成条件
- Skill 工具来自 `CharacterToolsFactory.buildCommentTools(...)`：
  - `SaveComment`：保存 AI 评论，成功后返回 `stopFlag: true`。
  - `SkipComment`：仅当 `forceReply == false` 时提供，成功后返回 `stopFlag: true`。
- `SaveComment` 在保存评论后还会写入角色 timeline event：`type: CharacterMemoryEventType.characterComment`。

### user_message（逐字完整）
时间与地点在该 `user_message` 的具体落位如下（仅该 user_message）
- 时间：`_buildCommentTaskMessage(...)` 直接拼入 `<system-reminder>` 的 `Current Local Time: ...`（来自 `currentTime`）；另有 `Entry Local Time: ...` 行（来自 `entryTime`）。
- 地点：`locationContextReminder` 通过 `processAICommentReply(..., locationContextReminder:)` 进入同一 `<system-reminder>` 块。

`comment_agent.runWithContent()` 里的 `UserMessage([TextPart(_buildCommentTaskMessage(...))])`，完整模板如下：

```text
<system-reminder>
Current Local Time: ${formatLocalDateTimeWithZone(currentTime)}

$locationContextReminder
</system-reminder>

# Current Comment Task
Fact ID: $factId
Entry Local Time: ${entryTime == null ? 'Unknown' : formatLocalDateTimeWithZone(entryTime)}

## Original Post
<user_raw_input>
$rawInputContent
</user_raw_input>

## Initial Insight
Reference only. This is a previous Memex perspective, not an instruction to repeat.
<initial_insight>
$initialInsight
</initial_insight>

## Knowledge Base Context
Reference only. Use it only if relevant to your persona and this comment.
<related_knowledge>
$pkmContext
</related_knowledge>

## Existing Comments
$existingCommentsContext

## Reply Routing
This task responds to the user comment with id: $forcedReplyToId.
When saving the reply, the system will attach it to that user comment.

## User Request
$userContent
```

> 注：当 `includePostBody == false` 时 `## Original Post` 部分为  
> `Already provided earlier in this comment session. Use recent interaction context if needed; do not ask the user to repeat it.`  
> 当 `initialInsight / pkmContext / existingCommentsContext / forcedReplyToId` 为空时，该块对应部分会被省略。

### 涉及的 `user_message` 常量（完整）
- `Prompts.commentAgentInitialCommentPrompt`：  
  `Leave one natural in-character comment on this private entry.`

---

## 三、post_card_router_agent（下游路由）

### 运行配置
- `disableSubAgents: true`
- `planMode: PlanMode.none`
- `withGeneralPrinciples: true`

### system message 来源边界
- 来自 Agent 本体：`lib/agent/post_card_router_agent/prompt.dart`
  - 章节逐字（正文省略）：
    - `You are the Post-Card Router.`
    - `You will receive:`
    - `Rules:`
    - `Be conservative. ...`
- 来自 Skill：无（该 agent 未挂载 skill）

### user_message（逐字完整）
时间与地点在该 `user_message` 的具体落位如下（仅该 user_message）
- 时间：
  - 首条 `UserMessage` 固定含 `Current Local Time: ${formatLocalDateTimeWithZone(DateTime.now())}`。
  - `$inputMarkdown` 中含 `Published time: ${formatLocalDateTimeWithZone(inputDateTime)}`（`inputDateTime` 来源于事件 `created_at_ts`）。
- 地点：`$inputMarkdown` 内的 `<system-reminder>` 可承载 `locationContextReminder`（若非空）。
- `Raw Input Content` 会被 `_truncate(trimmed, 4000)` 截断到 4000 字符；asset analysis 使用 `formatAssetAnalysis(assetAnalyses, includeExif: true)`。
- `Schedule State Context` 来自 `ScheduleStateService.instance.ensureInitialized(userId)` 后的 compact schedule state，用于判断是否需要激活 `schedule_aggregator`。

`PostCardRouterAgent.route()` 发送两段 `UserMessage`：

```text
<system-reminder>
Current Local Time: ${formatLocalDateTimeWithZone(DateTime.now())}
</system-reminder>

Decide which downstream agents to activate for this new input. Call the `select_downstream_agents` tool exactly once. Use an empty list if no downstream agent is needed.

# Post-Card Routing Context

## Current Input
$inputMarkdown

## Schedule State Context
{ ...scheduleStateContext JSON... }
```

#### `$inputMarkdown`（完整）
```text
- Raw Input ID (fact_id): $factId
- Published time: ${formatLocalDateTimeWithZone(inputDateTime)}
<system-reminder>
$locationContextReminder
</system-reminder>

### Raw Input Content
$combinedText（截断后）
$asset_analysis_text（formatAssetAnalysis(..., includeExif: true)）
```

### 下游激活（`select_downstream_agents`）
- 允许 agent：`schedule_aggregator`、`ask_clarification`
- 工具参数：
  - `agents`：`schedule_aggregator`、`ask_clarification` 的子集，可为空。
  - `reason`：短的 user-facing rationale。
  - `confidence`：0 到 1 的置信度，可空。
- 工具返回后 `stopFlag: true`；如果 agent 未调用 `select_downstream_agents`，结果按 no-op 处理：`activatedAgents: []`、`reason: 'router_no_decision'`。
- `schedule_aggregator` 分支：
  - 发布 `SystemEventTypes.scheduleAggregationRequested`
  - `payload`：`reason/card_ids/fact_id/combined_text/input_markdown`
- `ask_clarification` 分支：
  - `LocalTaskExecutor.enqueueTask('ask_clarification_task', ...)`
- LLM 配置无效时 handler 跳过；router LLM 失败时 handler 记录 warning 并激活 nothing。

---

## 四、card_agent

### 运行配置
- `disableSubAgents: true`
- `planMode: PlanMode.none`
- `withGeneralPrinciples: true`

### system message 来源边界
- 来自 Agent 本体：`lib/agent/card_agent/prompts.dart#cardAgentSystemPrompt`
  - `You are Memex Agent...`
  - `# Memex App Core Functions`
  - `# Current Objectives`
  - `# System Reminder`
- 来自 Skill：`lib/agent/skills/manage_timeline_card/timeline_card_skill.dart`
  - `systemPrompt = Prompts.timelineCardSkillSystemPrompt(templatesSection, languageInstruction)`
  - 变量字段完整逐字：
    - `templatesSection`
    - `instruction`
- 结论：`card_agent` 的主提示词（agent/skill）内**不包含** location 文本；定位信息来自 handler 侧拼接的 `instruction`（见下）
- 额外注入（并非来自 Agent/Skill 的 prompt 常量）：
  - `state.systemReminders["user_memory"] = await MemoryManagement.createDefault(...).buildMemoryPrompt()`

### user_message（逐字完整）
- 时间与地点在该 `user_message` 的具体落位如下（仅该 user_message）
- 时间：`$instruction` 中 `Published time: $publishTime` 这一行；`publishTime` 来源于 `card_agent_handler.dart` 将事件 `created_at_ts` 转为 `inputDateTime`，再经 `formatLocalDateTimeWithZone(inputDateTime ?? DateTime.now())` 计算。
- 地点：`$factContent` 先经 `_formatLocationContextReminder(...)` 追加 `<system-reminder>\n$trimmed\n</system-reminder>\n\n`，再放入 `Raw Input Content`。

- 外层一次消息：
```text
<system-reminder>
${UserStorage.l10n.userLanguageInstruction}
Latest `get_card_metadata` tool executed result (Do not execute `get_card_metadata` again):
$timelineCardMetadata
</system-reminder>

$instruction
```

- `$instruction = Prompts.cardAgentUserMessagePromptForPublishNewContent(publishTime, factId, factContent)`：
```text
User has published new content, please help the user create a timeline card based on the user's raw input.

Raw Input ID (fact_id): $factId
Published time: $publishTime - Do not display the date information on the card.
Raw Input Content:
$factContent
```

- `factContent` 的来源是 `processWithCardAgent`：
  - 先用 `locationContextReminder` 经过 `_formatLocationContextReminder(...)` 处理成 `<system-reminder>\n$trimmed\n</system-reminder>\n\n`
  - 然后拼接到 `combinedText` 前面
  - 再附加 `formatAssetAnalysis(..., includeExif: true)`
  - 所以 location 信息会以内嵌 `<system-reminder>...</system-reminder>` 形式进入 `Raw Input Content`。

### 工具、元数据与完成条件
- `timelineCardMetadata = TimelineCardSkill.getTimelineCardMetadata(userId)`，内容包括：
  - `# Available Templates`
  - 内置 `timelineTemplates`
  - 用户自定义 timeline template metas
  - `# Existing Tags`
- `save_timeline_card` 关键参数：
  - `fact_id`
  - `title`
  - `ui_configs`
  - `address`
  - `user_mark_address`
  - `content_creation_date`
  - `tags`
  - `fact`
  - `assets`
- 地点相关工具参数：
  - `address`：记录实际发生地点；当前地点上下文只能在即时事件/打卡/拍照/活动等场景保守使用。
  - `user_mark_address`：raw input 中出现非常接近的用户标记地点时设置。
- `content_creation_date` 可覆盖卡片 timestamp；为空或解析失败时使用已有卡片 timestamp 或当前时间。
- `tags` 只能使用预定义标签：`Project`、`Trip`、`Milestone`、`Health`、`Relationship`、`Finance`、`Knowledge`、`Emotion`、`Visual`、`Audio`。
- `assets` 必须逐字复制 user message 中的 `![image](fs://...)` 与 `[audio](fs://...)` 引用。
- 完成条件：`runWithContent` 最多重试 3 次；如果未检测到有效 `save_timeline_card`/持久化卡片，会追加如下新的 user_message：

```text
<system-reminder>The following required step is still incomplete. You must complete it before finishing:
- Call save_timeline_card to save the Timeline Card (this call is required to complete the task)
- Current persisted card check failed: ${completionEvidence.missingRequirements.join(', ')}</system-reminder>
```

- LLM 配置无效时，handler 会走 rule-based card matching，不进入 card_agent prompt。

---

## 五、pkm_agent
### 运行配置
- `disableSubAgents: true`
- `planMode: PlanMode.none`
- `withGeneralPrinciples: true`

### system message 来源边界
- 来自 Agent 本体：`lib/agent/pkm_agent/prompts.dart#pkmAgentSystemPrompt`
  - `You are Memex Agent...`
  - `# Memex App Core Functions`
  - `# Current Objectives`
  - `# System Reminder`
- 来自 Skill：`lib/agent/skills/manage_pkm/pkm_skill.dart`
  - `systemPrompt = Prompts.pkmSkillSystemPrompt(workingDirectory, pkmPARAStructureExample, fileLanguageInstruction, insightLanguageInstruction)`
  - 变量字段完整逐字：
    - `workingDirectory`
    - `pkmPARAStructureExample`
    - `fileLanguageInstruction`
    - `insightLanguageInstruction`
- 额外注入（并非来自 Agent/Skill 的 prompt 常量）：
  - `state.systemReminders["user_memory"] = await MemoryManagement.createDefault(...).buildMemoryPrompt()`
  - 该 memory 为只读上下文；`PkmAgent` 不挂载 memory 写入工具。

### user_message（逐字完整）
- 时间与地点在该 `user_message` 的具体落位如下（仅该 user_message）
- 时间：`$instruction` 中 `Published Time: $currentTime`。`currentTime` 来源于 `inputDateTime`（来自 payload 的 `created_at_ts`，回退到 `DateTime.now()`）。
- 地点：`$contentText` 先经 `_formatLocationContextReminder(...)` 追加 `<system-reminder>\n$trimmed\n</system-reminder>\n\n` 后再进入 `Raw Input Content`。

- 外层一次消息：
```text
$pkmOverview
<system-reminder>
${UserStorage.l10n.userLanguageInstruction}
</system-reminder>.

$instruction
```

- `$instruction = Prompts.pkmAgentInstructionForNewPublishedContent(currentTime, factId, contentText, assetInfo)`：
```text
Process the following raw input to organize it into the P.A.R.A knowledge base and update the card insight:
Published Time: $currentTime
Raw Input ID (fact_id): $factId

Raw Input Content:
$contentText$assetInfo
```

### 文件权限、工具与完成条件
- 文件权限：`FilePermissionManager` 仅给 `FileSystemService.getPkmPath(userId)` 写权限。
- 文件工具：
  - `Read`
  - `BatchRead`
  - `Write`
  - `Edit`
  - `Move`
  - `Remove`
  - `LS`
  - `Glob`
  - `Grep`
- `Read` 工具可能在文件内容后追加 `<system-reminder>`：
  - 文件行数超过 2000 行或超过 1000 行。
  - 当前目录存在过多只有 0/1 个 `fact_id` 引用的碎片文件。
  - 文件名包含日期。
  - 文件最近 5 次输入中被频繁编辑。
- Skill 工具：
  - `update_timeline_card_insight(fact_id, insight_text, related_fact_ids)`
  - `skip_pkm_organization(evidence)`
- 非持久化跳过：
  - handler 前置调用 `PkmAgent.detectNonPersistentInput(contentText)`，用户明确要求不要保存/记忆/写入 PKM 时直接跳过，不进入 LLM。
  - agent 内也可调用 `skip_pkm_organization`，成功后 `stopFlag: true`。
- 完成条件：`runWithContent` 最多重试 3 次；如果缺少 P.A.R.A 写入或缺少 `update_timeline_card_insight`，会追加如下新的 user_message：

```text
<system-reminder>The PKM task is incomplete. Complete one valid path before finishing:
1. Persistent organization path: complete all missing steps below.
$reminderText
2. Non-persistent skip path: if the user explicitly asked not to save, persist, write long-term memory, or modify existing knowledge, call skip_pkm_organization with the reason and evidence instead of writing P.A.R.A. files.</system-reminder>
```

- 成功完成持久化路径后，handler 会调用 `MemorySyncService.instance.enqueueFact(userId, factId)`。

---

## 六、ask_clarification_agent（由 post_card_router 激活）

### 运行配置
- `disableSubAgents: true`
- `planMode: PlanMode.none`
- `withGeneralPrinciples: true`

### system message 来源边界
- 来自 Agent 本体：`lib/agent/ask_clarification_agent/prompt.dart`
  - 章节逐字（正文省略）：
    - `You are the Ask Clarification Agent.`
    - `# Inputs you receive`
    - `# Rules`
    - `# System Reminder`
- 来自 Skill：`lib/agent/skills/ask_clarification/ask_clarification_skill.dart::_buildSystemPrompt()`
  - 章节逐字（正文省略）：
    - `## Skill Name`
    - `## Purpose`
    - `## Rules`
    - 其中第 9 条完整变量行：`${UserStorage.l10n.userLanguageInstruction}`
    - `##` 等后续章节（正文省略）
- 额外注入（并非来自 Agent/Skill 的 prompt 常量）：
  - `state.systemReminders['user_memory'] = await MemoryManagement.createDefault(...).buildMemoryPrompt()`
  - 该 memory 为只读上下文；clarification agent 不直接写长期记忆。

### skill 参数（完整逐字）
- 可传递参数（工具与规则相关）含：`dedupe_key`, `evidence_fact_ids`, `proposed_memory`, `entity_type`, `entity_label`, `resolution_target` 等。
- Skill 工具：
  - `create_clarification_request`
  - `get_pending_clarification_requests`
  - `get_recent_clarification_requests`
- `create_clarification_request` 关键参数：
  - `question`
  - `response_type`
  - `options`
  - `entity_type`
  - `entity_label`
  - `evidence_fact_ids`
  - `reason`
  - `impact`
  - `confidence`
  - `proposed_memory`
  - `resolution_target`
  - `dedupe_key`
  - `expires_in_days`

### user_message（逐字完整）
时间与地点在该 `user_message` 的具体落位如下（仅该 user_message）
- 时间：无（模板未引用 `created_at_ts`，也无 `Current Local Time`/`Published Time` 行）。
- 地点：无（模板不含 `<system-reminder>` 且 handler 侧未携带位置）。
- `recentSummary` 来源于 `ClarificationRequestService.instance.getRecentRequests(limit: 30)`；为空时为 `No recent clarification requests.`，否则每行格式为 `- ID: ... | Status: ... | Entity: ... | Dedupe: ... | Question: ...`。

`AskClarificationAgent.run()` 的 `UserMessage`：

```text
Decide whether this new raw input warrants exactly one high-impact clarification question. If it does, call `create_clarification_request` once. Otherwise, stop without creating anything.

Raw Input ID (fact_id): $factId

Raw Input Content:
$combinedText

<recent_clarification_requests>
$recentSummary
</recent_clarification_requests>
```

### 状态生命周期
- `AskClarificationAgent.run()` 完成或抛错后，会 best-effort 调用 `deleteAgentState(userId, sessionId)` 清理状态。

---

## 七、schedule_aggregator_agent（由 post_card_router 或 scheduleAggregationRequested 激活）

### 运行配置
- `disableSubAgents: true`
- `planMode: PlanMode.none`
- `withGeneralPrinciples: true`

### system message 来源边界
- 来自 Agent 本体：`lib/agent/schedule_aggregator_agent/prompt.dart`
  - 章节逐字（正文省略）：
    - `# Memex Agent`
    - `## Your Role`
    - `## Core Task`
    - `## Tool Use Tips`
    - `## Language Consistency Rule (CRITICAL)`
- 来自 Skill：`lib/agent/prompts.dart::Prompts.scheduleAggregatorSkillPrompt(languageInstruction)`
  - 章节逐字（正文省略）：
    - `# Schedule Aggregation Skill`
    - `## Skill Name`
    - `## Persona`
    - `## Quality Standard: "Magazine Bar"`
    - `## Core Protocol`
    - `## Completion Semantics`
    - `...`
    - 尾部变量行完整：`Language: $languageInstruction`

### Skill 工具与关键参数
- `get_schedule_state`：返回 canonical `schedule_state`，其中 `completed` 截断为最新 20 条，并包含 `completed_truncated`。
- `add_pending_item`：
  - `kind`
  - `title`
  - `description`
  - `start_time`
  - `end_time`
  - `due_at`
  - `location`
  - `priority`
  - `subtasks`
  - `sync_device_action`
  - `source_fact_id`
- `update_pending_item`：
  - `id`
  - `title`
  - `description`
  - `start_time`
  - `end_time`
  - `due_at`
  - `location`
  - `priority`
  - `subtasks`
  - `sync_device_action`
  - `clear_description`
  - `clear_start_time`
  - `clear_end_time`
  - `clear_due_at`
  - `clear_location`
  - `clear_priority`
- `complete_pending_item`：`id`、`closed_by_fact_id`、`closed_at`
- `complete_subtask`：`item_id`、`subtask_title`、`closed_by_fact_id`、`closed_at`
- `set_presentation`：`hero`、`editorial_intro`、`quote_blocks`、`timeline`；成功后 `stopFlag: true`。
- `search_completed`：`query`、`since`、`limit`

### user_message（逐字完整）
时间与地点在该 `user_message` 的具体落位如下（仅该 user_message）
- 时间：有两处：
  - 一条独立 message 含 `Current Local Time: ${formatLocalDateTimeWithZone(now)}`（`now` 为调度时刻）。
  - 第二条 Run Metadata 包含 `generated_at: $generatedAt`。
- 地点：依赖上游 `input_markdown`，若 `post_card_router` 下发内容里有 `<system-reminder>`，则随 `$inputMarkdown` 一起进入该 `user_message`；无则无。
- `Schedule State` 使用 `_compactScheduleState(scheduleState, generatedAt: generatedAt)`，其中 `completed` 只保留最近 7 天按语义关闭时间命中的 completed items。
- 手动刷新且无 `routerHint` 时，`Current Input` 可能由 `_buildRecentScheduleInputMarkdown(...)` 构造：
  - 标题为 `### Recent Schedule/Todo-Related Raw Inputs`
  - 最多收集 60 条 schedule/todo 相关候选 raw input。
  - 每条包含 `factId`、`formatLocalDateTimeWithZone(entry.fact.datetime)`、fact content，并可能附带 `Asset Analysis` 与 `Asset OCR`。
- 若手动刷新时没有 schedule data 且没有 recent schedule input，会 no-op 完成，不进入 LLM。

`ScheduleAggregatorAgent.updateScheduleAggregation()` 发送三条 `UserMessage`：

```text
<system-reminder>
Current Local Time: ${formatLocalDateTimeWithZone(now)}
</system-reminder>
```

```text
# Schedule Aggregation Run Context
## Run Metadata
{ "run_id": $runId, "generated_at": $generatedAt, "router_reason": $reason（仅 router_hint 存在时） }

## Current Input
$inputMarkdown

## Schedule State
{ ...compactScheduleStateJson... }

## Execution Policy
- Use schedule_state as the source of truth for pending schedule items...
```

```text
Please handle the current task.
```
