# Memex SuperAgent 子 agent 能力设计

## 方向确认

Memex 不需要先做复杂的 profile 层。当前阶段只设计一个轻量、通用、可并行的 SuperAgent 子 agent 机制：

```text
基础子 agent prompt + forceActivate skill + 基础工具 + 任务上下文
```

SuperAgent 仍然是唯一主入口。子 agent 不成为新的用户入口，也不恢复旧的后台 task pipeline。它只是 SuperAgent 在一个 turn 内启动的临时 worker，用来并行处理记录意图中的不同分支，降低延迟并隔离上下文。

对记录 capture 场景，默认可并行启动三个子 agent：

```text
card child      -> forceActivate manage_timeline_card
pkm child       -> forceActivate manage_pkm
schedule child  -> forceActivate update_schedule_aggregation
```

这不是恢复旧 `card_agent_task / pkm_agent_task / schedule_aggregator_task`，因为：

- 它们不是后台任务队列入口。
- 它们不是长期 agent。
- 它们不拥有用户对话。
- 它们不从事件总线固定触发。
- 它们由 SuperAgent 当轮启动、等待、合并、解释。
- 它们使用同一套 child runtime，只是 forceActivate 不同 skill。

## 设计目标

1. SuperAgent 是唯一主入口。
2. 子 agent 是一次性 worker，不跨 turn 持久化。
3. 子 agent 不复用 `superAgentSystemPrompt`。
4. 子 agent 默认只接收当前任务上下文，不继承父 agent 完整历史。
5. 子 agent 通过 `forceActivateSkills` 获得当前任务需要的 skill。
6. 子 agent 使用基础工具集，但写权限仍由 runtime/permission manager 限制。
7. 父 SuperAgent 负责最终完成判断和最终用户回复。
8. 子 agent 可以返回 no-op，避免为了完成任务而强行写入。

## 为什么和最佳实践对齐

Hermes/OpenClaw/Codex 的重点不是“必须避免多个子 agent”，而是避免把子 agent 做成失控的第二套入口或固定业务系统。最佳实践的共同点是：

- 子 agent 是 runtime 管理的临时执行单元。
- 子 agent 有独立上下文和专用 prompt。
- 子 agent 工具/权限由 harness 控制。
- 父 agent 拥有最终用户语义。
- 子 agent 结果回到父 agent，由父 agent 综合。

因此，记录意图默认并行三个 child 是可以成立的，只要它们是 SuperAgent runtime 下的临时 worker，并且每个 child 的任务边界、skill、工具和完成语义都被限制住。

## 核心架构

```text
User input
  |
  v
SuperAgent detects record intent
  |
  v
create CaptureRunContext
  |
  +--> card child      (base prompt + manage_timeline_card)
  +--> pkm child       (base prompt + manage_pkm)
  +--> schedule child  (base prompt + update_schedule_aggregation)
  |
  v
SuperAgentSubagentRuntime waits / validates / merges
  |
  v
SuperAgent final response
```

SuperAgent 决定是否进入 capture 子 agent 模式。非记录意图不启动这三个 child。

## 子 agent 创建参数

建议新增统一配置：

```dart
class SuperAgentChildConfig {
  final String childRunId;
  final String parentSessionId;
  final String childName;
  final String taskBrief;
  final Map<String, dynamic> contextPacket;
  final List<String> forceActivateSkills;
  final List<String> allowedBaseTools;
  final ChildWriteScope writeScope;
  final Map<String, dynamic> outputSchema;
  final Duration timeout;
}
```

第一阶段不引入 profile。`childName` 只用于日志和 UI，例如：

- `card_child`
- `pkm_child`
- `schedule_child`

它不是业务 agent 类型，也不对应旧 task handler。

## 基础子 agent prompt

所有子 agent 使用同一个基础 prompt，再追加当前强制激活的 skill 信息和任务 brief。

```text
# Memex Subagent Worker

You are a temporary worker spawned by Memex SuperAgent for one bounded task.

You are not the user-facing SuperAgent. Do not chat with the user. Do not ask
questions directly to the user. Return structured results only to the parent
SuperAgent runtime.

## Scope
- Work only on the task brief and context packet provided in this run.
- Follow the active skill instructions for this child run.
- Use only the fact_id, timestamps, assets, and context explicitly provided.
- Do not infer or invent missing record identity.
- Do not perform side effects outside your assigned write scope.
- Do not write long-term memory.
- Do not spawn other agents.

## Truthfulness
- Report tool failures truthfully.
- Never claim a change was completed unless the tool result proves it.
- If your branch does not apply, return `no_op` with a short reason.
- If required information is missing, return `needs_parent_input` with the exact missing field.

## Output
Return the structured result requested by the parent runtime. Do not produce
user-facing prose unless explicitly requested.
```

每个 child 启动时追加：

```text
## Active Skills for This Child Run
- <skill_name>

These skills are active only for this child run. They do not persist to the
parent SuperAgent or other children. If a skill instruction conflicts with the
task brief, write scope, or this system prompt, the runtime scope wins.
```

## 三个记录分支

### Card child

启动配置：

```text
forceActivateSkills: [manage_timeline_card]
childName: card_child
```

职责：

- 为当前记录创建或更新 Timeline Card。
- 使用父 runtime 提供的 `fact_id`、输入内容、附件分析、时间和位置上下文。
- 保存 completed card。

禁止：

- 不组织 PKM。
- 不更新 schedule。
- 不写 memory。
- 不向用户回复。

输出：

```json
{
  "status": "completed | failed | needs_parent_input",
  "fact_id": "...",
  "card_changed": true,
  "evidence": {
    "save_tool_called": true,
    "card_exists": true,
    "status_completed": true,
    "has_title": true,
    "has_ui_configs": true
  },
  "summary": "..."
}
```

### PKM child

启动配置：

```text
forceActivateSkills: [manage_pkm]
childName: pkm_child
```

职责：

- 判断当前记录是否值得进入 P.A.R.A. 知识库。
- 如果值得，写入或更新 PKM 条目。
- 使用同一个 `fact_id` 建立回链。
- 必要时更新 card insight，但必须等 card 已存在。

禁止：

- 不创建 card。
- 不更新 schedule。
- 不写 memory。
- 不改 `/Facts`、`_UserSettings`、`_System`。

输出：

```json
{
  "status": "completed | no_op | failed | needs_parent_input",
  "fact_id": "...",
  "pkm_changed": true,
  "card_insight_updated": true,
  "changed_files": ["/PKM/..."],
  "reason": "...",
  "summary": "..."
}
```

`no_op` 是正常结果。例如随手一条低信息量记录不需要 PKM。

### Schedule child

启动配置：

```text
forceActivateSkills: [update_schedule_aggregation]
childName: schedule_child
```

职责：

- 判断当前记录是否影响 schedule。
- 如果包含任务、计划、截止日期、事件、完成状态，则更新 schedule state 或 presentation。
- 如果不涉及 schedule，返回 no-op。

禁止：

- 不创建 card。
- 不组织 PKM。
- 不写 memory。
- 不读取无关 Cards/PKM。

输出：

```json
{
  "status": "completed | no_op | failed | needs_parent_input",
  "fact_id": "...",
  "schedule_changed": true,
  "reason": "...",
  "summary": "..."
}
```

`no_op` 是正常结果，不应被当作失败。

## CaptureRunContext

为了并行，runtime 应先生成一个共享上下文：

```dart
class CaptureRunContext {
  final String parentSessionId;
  final String captureRunId;
  final String userId;
  final String factId;
  final String inputMarkdown;
  final String combinedText;
  final DateTime capturedAt;
  final String? locationContextReminder;
  final List<Map<String, dynamic>> assetAnalyses;
  final Map<String, dynamic>? existingCardSnapshot;
  final Map<String, dynamic>? scheduleStateSnapshot;
}
```

关键点：

- `factId` 由 runtime 提供，不能由 child 猜。
- 三个 child 共享同一个 `factId`。
- 附件分析结果由父 runtime 提供，child 不重复分析。
- `scheduleStateSnapshot` 只给 schedule child。
- `existingCardSnapshot` 只在更新已有 card 时提供。

如果当前系统暂时不能在保存 card 前预留 fact_id，可先采用两阶段兼容模式：

1. card child 先运行并返回真实 fact_id。
2. pkm child 和 schedule child 再并行运行。

但目标设计应是 runtime 先预留 fact_id，从而三路真正并行。

## 基础工具集

第一阶段不做复杂工具分层，但仍需要最小权限。

建议 child 基础工具包括：

- `Read`
- `BatchRead`
- `Grep`
- `Glob`
- `LS`
- `getCurrentTime`

写入能力不通过基础工具默认开放，而由激活 skill 的 tool 和 `writeScope` 控制。

如果确实要给基础 `Write/Edit/Move/Remove`，必须按 child 限制：

- card child：只能通过 `manage_timeline_card` 写 card，不给通用写文件工具。
- pkm child：只允许 `/PKM` 范围写入。
- schedule child：只允许 schedule skill 写 schedule state。

## forceActivateSkills 语义

`forceActivateSkills` 只对 child run 生效：

- 不污染父 SuperAgent 的 active skills。
- 不影响其他 child。
- 不跨 turn 保留。
- child 完成、失败、取消后立即失效。

child factory 内部应复用现有 skill 机制，对匹配 skill 设置：

```dart
skill.forceActivate = true;
```

runtime 必须校验：

- skill 存在。
- skill 当前环境可用。
- skill 被 SuperAgent 允许用于子 agent。
- skill 的写入能力不突破 child write scope。

## 并行与依赖

推荐目标流程：

```text
reserve fact_id
  |
  +--> card child
  +--> pkm child
  +--> schedule child
  |
  v
wait all children
  |
  v
validate results
  |
  v
SuperAgent final reply
```

需要处理一个依赖：PKM child 如果要更新 card insight，必须等 card 存在。

可选实现：

- PKM child 先完成 PKM 文件组织，返回 `pending_card_insight_update`。
- runtime 在 card child 完成后允许 PKM child 继续或由父 SuperAgent 执行 insight update。

为了第一版简单，也可以让 PKM child 不直接更新 card insight，只返回建议 insight，由父 SuperAgent 在所有 child 完成后统一写入。

## 写入冲突控制

必须有 runtime 写锁：

- 同一 `fact_id` 的 card 写入锁。
- `/PKM` 文件级写入锁。
- schedule state 写入锁。

SuperAgent 在等待 child 时不应同时写同一资源。

## 结果合并

父 SuperAgent 收到三路结果后，按规则合并：

- card completed：可以告诉用户记录已保存。
- card failed：不能告诉用户记录已保存，即使 PKM/schedule 成功。
- pkm no-op：不需要向用户强调，除非用户问。
- schedule no-op：不需要向用户强调，除非用户问。
- pkm failed：可说明卡片已保存，但知识库组织失败。
- schedule failed：可说明卡片已保存，但日程未更新。
- needs_parent_input：父 SuperAgent 决定是否问用户，或保守跳过该分支。

## 为什么默认三路仍然不是旧 pipeline

默认三路适用于“记录意图”这个高频场景，因为它能提升速度并隔离上下文。但它仍不同于旧 pipeline：

- 触发点是 SuperAgent 对当前用户意图的判断，不是全局事件订阅。
- 三个 child 是同一 child runtime 的不同 skill 激活，不是三套长期 agent。
- child 结果必须回到父 SuperAgent 合并。
- no-op 是一等结果，PKM/schedule 不需要强行写。
- 父 SuperAgent 可以对非记录意图不启动 child。
- 父 SuperAgent 可以对简单修复、查询、配置等任务直接使用 skill，不走三路。

## 实现分期

### Phase 1: child runtime

新增：

- `SuperAgentSubagentRuntime`
- `SuperAgentChildConfig`
- `CaptureRunContext`
- `SuperAgentChildResult`
- 基础 child prompt builder
- child activity logging

### Phase 2: forceActivate skill child factory

新增统一 child factory：

```dart
Future<StatefulAgent> createSuperAgentChild({
  required SuperAgentChildConfig config,
  required LLMClient client,
  required ModelConfig modelConfig,
  required String userId,
})
```

它做：

- 创建独立 `AgentState`。
- 注入基础 child prompt。
- 设置 `forceActivateSkills`。
- 配置基础工具。
- 配置 `FilePermissionManager`。
- `disableSubAgents: true`。
- 设置 timeout。

### Phase 3: capture fan-out tool

给 SuperAgent 增加一个高层工具：

```text
run_record_capture_children
```

这个工具只处理记录意图，内部并行启动 card / pkm / schedule 三个 child。

SuperAgent prompt 中说明：

- 当用户意图是 durable capture，优先使用 `run_record_capture_children`。
- 非记录意图不要使用。
- 简单查询、修复、配置仍直接用对应工具/skill。

### Phase 4: validators

实现 deterministic validators：

- card saved validator。
- PKM fact_id reference validator。
- schedule changed/no-op validator。

### Phase 5: UI activity tree

展示：

```text
Recording capture
├─ Card: completed
├─ PKM: no-op
└─ Schedule: completed
```

## SuperAgent prompt 调整建议

加入：

```text
## Record Capture Children
When the user intent is durable record capture, prefer `run_record_capture_children`.
It runs temporary child workers in parallel for card creation, PKM organization,
and schedule update. Each child has a narrow prompt and a force-activated skill.
You remain responsible for the final user-facing reply.

Do not use record capture children for ordinary Q&A, app configuration, broad
search, or simple single-artifact edits. For those, use the relevant skill or
read/search tools directly.
```

同时保留 truthfulness：

```text
Only tell the user a record was saved if the card child returned verified
completion. Treat PKM/schedule no-op as normal. Report PKM or schedule failures
plainly when relevant.
```

## 最终结论

当前阶段的最简正确方案是：

```text
SuperAgent unique entry
  + record intent detector
  + run_record_capture_children
      + one generic child runtime
      + base child prompt
      + forceActivate skill
      + basic tools
      + scoped permissions
      + structured result
```

这既保留了并行收益，也避免把系统重新做成一堆固定长期 agent。对于 Memex 的高频记录场景，默认并行 card / PKM / schedule 是可以接受的，前提是 no-op 是正常结果、写入受限、最终用户语义由 SuperAgent 统一负责。
