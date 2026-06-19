# Memex SuperAgent 子 agent 能力设计（Skill-shaped 版本）

## 设计修正

子 agent 不是恢复旧的固定捕获流水线。

Hermes 和 OpenClaw 的最佳实践不是“系统里预置一堆固定子 agent 组成 pipeline”，而是提供一个受 harness 管理的 delegation primitive：主 agent 在需要时把一个边界清楚的子任务交给临时 worker，runtime 负责上下文隔离、工具限制、深度/并发/超时、结果回收和可观测性。

Memex 应该采用同样思路：SuperAgent 仍然是唯一主入口；子 agent 是 SuperAgent 的一种临时执行能力，而不是新的业务流程入口。

## 目标

1. SuperAgent 是唯一用户入口。
2. 子 agent 是临时 worker，不是长期 agent，不是旧任务队列 pipeline。
3. 子 agent prompt 不能复用 `superAgentSystemPrompt`。
4. 子 agent 默认不继承父 agent 完整历史，只接收父 agent 精选的任务上下文。
5. 子 agent 工具面由 runtime 按任务授予，不能默认获得 SuperAgent 全部 skill。
6. 父 SuperAgent 负责最终判断、最终提交策略和最终用户回复。
7. 子 agent 的核心价值是并行探索、并行草拟、并行诊断、并行执行低冲突子任务，而不是强制把每次 capture 拆成固定三段。

## 对 Hermes / OpenClaw 的正确理解

### Hermes

Hermes 的 `delegate_task` 是通用 delegation 工具。它不是固定的 card agent、PKM agent、schedule agent 集合。

它的关键机制是：

- 父 agent 为子 agent 提供一个具体 goal/context。
- 子 agent 是 fresh conversation。
- 子 agent prompt 是 focused worker prompt。
- 子 agent 工具集由 toolsets 计算，并和父工具集求交集。
- 默认屏蔽递归 delegation、clarify、memory、send_message、execute_code 等高风险能力。
- depth、concurrency、timeout、approval callback 由 runtime 控制。

### OpenClaw

OpenClaw 的 `sessions_spawn` 也是通用 spawn 能力。它不是一堆预定义业务 worker。

它的关键机制是：

- spawn 一个新的 session/run。
- 注入 subagent 专用 prompt，强调 focused、ephemeral、不要 polling、不要和用户聊天。
- depth 决定 role：main / orchestrator / leaf。
- runtime 检查 allowlist、max depth、max children、sandbox、thread binding。
- 完成结果通过 announce 返回 parent。

### 给 Memex 的启发

Memex 不应该做“固定 card/PKM/schedule 子 agent pipeline”。正确抽象是：

```text
SuperAgent owns user intent and final answer.
Subagent runtime owns temporary delegated work.
Child workers own one bounded task and return evidence.
```

card、PKM、schedule 只是 SuperAgent 可能拆出去的任务类型，不是每次 capture 必跑的系统阶段。

## 核心能力：SuperAgent Subagent Runtime

新增 `SuperAgentSubagentRuntime`，提供 SuperAgent 内部可用的受控 delegation 能力。

```text
User
  |
  v
SuperAgent main loop
  |
  | decides whether delegation helps
  v
SuperAgentSubagentRuntime
  |
  +-- child worker A: bounded task
  +-- child worker B: bounded task
  +-- child worker C: bounded task
  |
  v
structured child results + evidence
  |
  v
SuperAgent synthesis / final response / optional commit
```

这个 runtime 不替代 SuperAgent。它只提供：

- spawn
- wait
- cancel
- result collection
- permission scoping
- timeout
- activity logging
- optional validators

## 父 agent 可见工具

建议不要一开始做 `run_capture_subagents` 这种业务强绑定工具。它会把设计重新拉回旧流程。

推荐暴露更通用但受限的工具：

```text
spawn_memex_subagent(
  task_title,
  task_brief,
  context_packet,
  profile,
  allowed_capabilities,
  output_schema,
  write_policy,
  timeout_seconds
)

wait_memex_subagents(child_run_ids, timeout_seconds)

cancel_memex_subagent(child_run_id)
```

### `profile`

`profile` 不是固定业务 agent，而是 prompt/tool policy preset。

建议第一批 profile：

- `readonly_researcher`：只读检索、诊断、总结。
- `artifact_worker`：可写一个明确 artifact，如一个 card 或一个 PKM 文件。
- `planner`：只做分解/建议，不写入。
- `validator`：只做校验，不写入。

以后可以增加更具体 profile，但不要把 profile 设计成固定业务 pipeline。

### `allowed_capabilities`

父 agent 必须显式声明能力范围，例如：

```json
{
  "read": ["/Cards", "/PKM"],
  "write": ["/PKM/Projects/Memex.md"],
  "skills": ["manage_pkm"],
  "forbidden": ["manage_memory", "remove", "external_share"]
}
```

runtime 要以权限规则实际 enforce，而不是只写在 prompt 里。

### `write_policy`

建议支持三种：

- `proposal_only`：子 agent 不能写，只返回 patch/proposal。
- `scoped_write`：子 agent 只能写指定资源。
- `parent_commit`：子 agent 可调用工具生成结构化变更，但最终提交由父 agent 或 runtime 完成。

默认应是 `proposal_only` 或 `parent_commit`，只有低风险且边界明确的任务才用 `scoped_write`。

## 子 agent prompt

子 agent prompt 不能复用 `superAgentSystemPrompt`。SuperAgent prompt 是用户入口 prompt，包含聊天、捕获、配置、记忆、查询、技能管理等太多职责。子 agent 需要 worker prompt。

### 基础 prompt

```text
# Memex Subagent Worker

You are a temporary worker spawned by Memex SuperAgent for one bounded task.

You are not the user-facing SuperAgent. Do not chat with the user. Do not ask
questions directly to the user. Return results only to the parent SuperAgent.

## Scope
- Work only on the task described in this message.
- Use only the context packet provided by the parent.
- Do not assume missing facts. If a required field is missing, return
  `needs_parent_input` with the exact missing field.
- Do not perform side effects outside the assigned write scope.
- Do not use tools or skills outside the allowed capabilities.
- Do not spawn other agents.
- Do not write long-term memory.

## Completion
- Report tool failures truthfully.
- Never claim a change was completed unless the tool result or validator proves it.
- Return structured output matching the requested output schema.
```

### Profile prompt additions

`readonly_researcher`：

```text
## Profile: readonly_researcher

You may inspect existing data and summarize findings. You must not create,
modify, move, or delete files. Prefer targeted search/read over broad scanning.
Your output should be evidence-based and cite the files or records inspected.
```

`artifact_worker`：

```text
## Profile: artifact_worker

You may modify only the artifact paths explicitly assigned in the task. Do not
create unrelated artifacts. If the requested write would require a broader
change, stop and return `needs_parent_input` or `blocked_by_scope`.
```

`planner`：

```text
## Profile: planner

You do not write data. Produce a concise plan, risks, and recommended next
actions for the parent SuperAgent. Do not execute the plan.
```

`validator`：

```text
## Profile: validator

You do not write data. Check whether the specified result is actually complete
using available read-only evidence. Return pass/fail and missing requirements.
```

## 什么时候使用子 agent

SuperAgent 应在“并行能明显降低延迟或降低上下文污染”时使用子 agent。

适合：

- 一个用户请求天然包含多个独立问题。
- 一个 capture 需要同时判断视觉呈现、知识归档、日程相关性，但这些判断互不依赖。
- 需要比较多个候选方案，例如不同卡片模板、不同 PKM 归档位置、不同修复策略。
- 需要让一个 worker 做只读诊断，父 agent 同时继续组织当前回复。
- 需要校验某个复杂工具结果是否真的落盘成功。

不适合：

- 简单问答。
- 单一明确 tool call 就能完成的任务。
- 高风险写入需要用户确认。
- 子任务之间强依赖，无法并行。
- 父 agent 自己还没弄清任务边界。

## Capture 场景的正确用法

Capture 可以受益于子 agent，但不应该固定拆成“card + PKM + schedule 三 worker”。

更合理的策略是由 SuperAgent 动态判断：

### 简单输入

例如：“买了杯咖啡，还不错。”

SuperAgent 可能直接调用 `manage_timeline_card`，不需要子 agent。

### 信息密集输入

例如一段会议纪要，包含任务、项目决策和日期。

SuperAgent 可以：

- 自己负责核心 card 保存，确保用户可见记录尽快落盘。
- 并行 spawn 一个 `readonly_researcher` 或 `planner` 子 agent 判断 PKM 归档位置。
- 并行 spawn 一个 `validator` 或 `planner` 子 agent 判断 schedule 是否应更新。
- 根据子 agent 返回结果决定是否调用对应 skill 或让 scoped worker 写入。

### 多候选设计输入

例如用户上传一组图片并要求“做成好看的记录”。

SuperAgent 可以 spawn 多个 `planner` 子 agent，各自提出 card layout / narrative angle，父 agent 选一个并提交。

### 修复场景

例如用户说“这张卡还是不对”。

SuperAgent 可以 spawn 一个 `readonly_researcher` 做数据诊断，同时自己准备用户可见回复或等待结果后修复。

## 结果协议

所有子 agent 返回统一 envelope。

```dart
class SuperAgentChildResult {
  final String childRunId;
  final String parentSessionId;
  final String profile;
  final String taskTitle;
  final String status; // completed | no_op | needs_parent_input | blocked_by_scope | failed | timeout
  final Map<String, dynamic> evidence;
  final List<String> changedResources;
  final String summary;
  final String? error;
}
```

子 agent 不返回自由散文作为唯一结果。父 agent 需要拿到结构化 evidence。

## 上下文策略

子 agent 默认不继承父完整 history。

父 agent 传入：

- 当前用户请求的必要片段。
- 当前 task 的目标。
- 相关 record/card/pkm/schedule 的最小上下文。
- 明确的 allowed paths / allowed skills。
- 输出 schema。

不传入：

- 父 agent 完整聊天历史。
- 父 agent 所有 system reminders。
- 父 agent 全部 activated skills。
- 用户长期 memory 全量内容，除非任务明确需要。

如果必须继承上下文，应使用 filtered context：只保留用户意图、已确认事实、已完成工具结果摘要，不保留 tool trace 和模型推理。

## 工具与权限

子 agent 工具集由 runtime 动态构造，不从 SuperAgent 复制。

建议规则：

- 默认只读。
- 写入必须声明路径或 artifact id。
- 禁止 `manage_memory`。
- 禁止删除，除非父 agent 显式授权且用户已确认。
- 禁止外部分享/发送。
- 禁止子 agent 再 spawn 子 agent。
- 文件工具必须使用 `FilePermissionManager` enforcement。

## 生命周期

子 agent 是单任务、短生命周期对象。

- 创建于一次 SuperAgent turn。
- 结束后只保留 result、evidence、activity log。
- 不延续到下一轮用户对话。
- 不自动携带 activated skills。
- 不成为独立用户会话。

这点非常重要：子 agent 是 SuperAgent 的执行工具，不是新的 Memex agent 产品形态。

## 并发控制

runtime 应提供：

- 每 turn 最大 child 数，例如 3。
- 每 child timeout。
- 全局 LLM 并发上限。
- 同一路径写锁。
- 同一 card/fact_id 写锁。
- cancel propagation。

如果子 agent 已经修改资源，父 agent 的后续写入必须看到最新状态或通过 validator 重新检查。

## 完成校验

校验应按任务声明，而不是按固定业务类型。

示例：

```json
{
  "validator": "file_contains",
  "path": "/PKM/Projects/Memex.md",
  "must_contain": ["fact_id: 2026/06/16.md#ts_3"]
}
```

```json
{
  "validator": "card_completed",
  "fact_id": "2026/06/16.md#ts_3",
  "requirements": ["exists", "status_completed", "title", "ui_configs"]
}
```

```json
{
  "validator": "schedule_noop_or_changed",
  "input_id": "2026/06/16.md#ts_3"
}
```

父 SuperAgent 可以按需要请求 validator profile 子 agent 做只读复核，也可以由 runtime 直接执行 deterministic validator。

## 与旧专用 agent 的关系

不要恢复旧 task pipeline。

可以复用：

- 旧 prompt 中的角色边界经验。
- 旧工具和 skill 实现。
- 旧 completion evidence 的 deterministic 检查思路。
- 旧 handler 中对附件、地点和时间上下文的输入组织经验。

不应复用为主路径：

- 固定捕获 task 类型
- 固定 userInputSubmitted fan-out
- “输入发布后必跑一串 agent”的架构

## 推荐实现分期

### Phase 1: 通用 runtime，不接业务 pipeline

新增：

- `SuperAgentSubagentRuntime`
- `SuperAgentChildProfile`
- `SuperAgentChildTaskPacket`
- `SuperAgentChildResult`
- child lifecycle logging

只支持 `proposal_only` 和 `readonly_researcher`，先验证上下文隔离和活动展示。

### Phase 2: 受限写入

增加：

- `artifact_worker`
- path-scoped write permission
- write locks
- deterministic validators

### Phase 3: SuperAgent tool 暴露

新增：

- `spawn_memex_subagent`
- `wait_memex_subagents`
- `cancel_memex_subagent`

并在 SuperAgent prompt 中说明：只有在任务可并行、边界清楚时使用。

### Phase 4: Capture 加速作为使用场景，而不是 pipeline

让 SuperAgent 在复杂 capture 中按需使用子 agent：

- 并行做只读分析。
- 并行提出 PKM/schedule 建议。
- 必要时使用 scoped worker 写入明确 artifact。

但简单 capture 仍可直接由 SuperAgent 使用 skill 完成。

### Phase 5: UI 可观测性

Agent Activity 展示 child tree：

```text
SuperAgent handling capture
├─ child: check schedule relevance completed
├─ child: propose PKM placement completed
└─ parent: saved card and replied
```

## SuperAgent prompt 调整建议

主 prompt 只加入 delegation 规则，不加入 worker 细节。

建议文案：

```text
## Delegation
You can delegate bounded subtasks to temporary Memex subagents when it will
materially reduce latency or isolate context. Subagents are not user-facing and
must receive a narrow task, explicit context, allowed capabilities, and an output
schema. Do not use subagents for simple single-tool tasks. You remain responsible
for final user-facing completion and truthfulness.
```

再加入反滥用规则：

```text
Do not recreate the old fixed card/PKM/schedule pipeline. For capture, use
subagents only when the current input genuinely benefits from parallel analysis
or scoped artifact work. Otherwise call the relevant skill directly.
```

## Skill-shaped 子 agent

通用子 agent 不应该通过“创建更多 agent 类型”来获得不同能力，而应该通过启动参数临时塑形能力：父 SuperAgent 在派发任务时可以指定 `forceActivateSkills`，runtime 用同一套 child agent factory 创建 worker，但为该 child run 强制激活一个或多个 skill。

这可以同时满足两个目标：

- 子 agent primitive 保持通用，不退化成固定业务 agent 列表。
- 每个 child run 又能拥有足够窄、足够强的专业能力。

### spawn 参数扩展

建议 `spawn_memex_subagent` 增加：

```text
spawn_memex_subagent(
  task_title,
  task_brief,
  context_packet,
  profile,
  allowed_capabilities,
  force_activate_skills,
  output_schema,
  write_policy,
  timeout_seconds
)
```

其中 `force_activate_skills` 是 skill name 列表，例如：

```json
{
  "profile": "artifact_worker",
  "force_activate_skills": ["manage_pkm"],
  "allowed_capabilities": {
    "read": ["/PKM"],
    "write": ["/PKM/Projects/Memex.md"],
    "skills": ["manage_pkm"]
  }
}
```

### 语义

`forceActivateSkills` 的含义是：

- 只在这个 child run 内生效。
- 不污染父 SuperAgent 的 active skills。
- 不自动带到其他 child。
- 不跨 turn 持久化。
- child 完成、失败、取消后立即失效。

这与 SuperAgent 自己的 skill 生命周期不同。父 agent 的 skill 激活服务于用户对话；child 的 skill 激活服务于一次 bounded task。

### runtime 校验

父 agent 不能任意 force activate 所有 skill。runtime 必须校验：

1. skill 存在。
2. skill 被当前用户/环境允许。
3. skill 与 child `profile` 兼容。
4. skill 在 `allowed_capabilities.skills` 中。
5. skill 暴露的工具不会突破 child 的文件权限和 write policy。

如果校验失败，spawn 应返回明确错误，而不是让模型在 prompt 里自行遵守。

示例规则：

```text
readonly_researcher:
  allowed forced skills: timeline_diagnostics, knowledge_insight(readonly mode)
  forbidden forced skills: manage_pkm, manage_timeline_card, manage_memory

artifact_worker:
  allowed forced skills: manage_pkm, manage_timeline_card, dynamic_timeline_ui
  requires scoped write policy

validator:
  allowed forced skills: timeline_diagnostics
  forbidden forced skills: any write skill

planner:
  allowed forced skills: none by default, or read-only skill docs only
```

### tool scope 交集

最终 child tools 应该是三者交集，而不是简单相加：

```text
child_tools = tools(profile) ∩ tools(forceActivateSkills) ∩ tools(allowed_capabilities)
```

如果某个 forced skill 需要的工具没有被允许，runtime 有两个选择：

- spawn 失败并返回缺失 capability。
- 以降级模式启动，但在 child prompt 中明确该 skill 的某些动作不可用。

推荐第一版采用失败策略，避免模型以为自己能完成实际不能完成的任务。

### child system prompt 中的 skill 注入

child prompt 应明确说明本次任务已强制激活哪些 skill：

```text
## Active Skills for This Worker
+ manage_pkm

These skills are active only for this child run. Follow their instructions for
this bounded task, but do not use them outside the assigned scope. If a skill
instruction conflicts with the task scope, allowed paths, write policy, or this
system prompt, the runtime scope wins.
```

具体 skill body 是否全量注入，取决于现有 `dart_agent_core` skill 机制。如果 `StatefulAgent` 已支持 `forceActivate`，child factory 应复用同一机制：创建 child agent 时对匹配 skill 设置 `forceActivate = true`。这样 skill 最终如何进入模型消息由 core 保持一致。

### 为什么这比固定子 agent 更好

固定业务子 agent 会让系统重新变成：

```text
card agent / PKM agent / schedule agent / insight agent / ...
```

这会带来旧 pipeline 的问题：

- 每次 capture 都容易被过度处理。
- agent 数量随业务增长膨胀。
- prompt 和工具边界散落在多个入口。
- SuperAgent 的“唯一入口”被弱化。

`forceActivateSkills` 则让能力组合发生在 runtime：

```text
same child primitive + profile + forced skills + scoped permissions = task-specific worker
```

例如：

```text
planner + no forced skill
  -> 只做方案比较

readonly_researcher + timeline_diagnostics
  -> 只读检查卡片问题

artifact_worker + manage_pkm + /PKM scoped write
  -> 组织一个明确 PKM artifact

artifact_worker + dynamic_timeline_ui + one template path write
  -> 设计或修复一个动态卡片模板

validator + timeline_diagnostics
  -> 校验某张卡是否真的满足修复要求
```

这种组合式能力更接近 Hermes/OpenClaw 的最佳实践：子 agent 是通用执行容器，专业性来自任务上下文、工具/skill 暴露和 runtime 约束。

### 对 SuperAgent 的 prompt 补充

建议在 SuperAgent prompt 的 delegation 部分增加：

```text
When spawning a subagent, shape its capability with a narrow profile and, when
needed, force-activate the exact skill required for the task. Prefer this over
creating named business subagents. Forced skills are temporary and apply only to
that child run. Never force-activate broad write skills unless the task includes
an explicit write scope and the user intent justifies it.
```

再加一条反滥用规则：

```text
Do not use forced skills to bypass your own skill lifecycle or permissions. If a
child needs `manage_pkm`, its allowed capabilities must include only the PKM paths
it is permitted to touch. If the scope is unclear, ask the user or do a read-only
subagent first.
```

### 实现落点

建议 child factory 接收：

```dart
class SuperAgentChildConfig {
  final SuperAgentChildProfile profile;
  final List<String> forceActivateSkills;
  final ChildAllowedCapabilities allowedCapabilities;
  final ChildWritePolicy writePolicy;
  final String taskTitle;
  final String taskBrief;
  final Map<String, dynamic> contextPacket;
  final Map<String, dynamic> outputSchema;
}
```

child factory 内部：

1. 构造 profile 对应 system prompt。
2. 构造最小 tools。
3. 构造候选 skills。
4. 对 `forceActivateSkills` 命中的 skill 设置 `forceActivate = true`。
5. 用 `FilePermissionManager` enforce allowed paths。
6. 禁用 child subagents。
7. 设置独立 `AgentState` 和 timeout。

这样同一套 child agent runtime 可以形成不同能力，而不会把架构退回到一堆固定 agent。

## 最终判断

Memex 需要的不是“一堆子 agent”，而是一个可控的 subagent harness primitive。

正确设计是：

- SuperAgent 是唯一主入口。
- 子 agent 是临时并行执行能力。
- prompt 是按任务生成的 worker prompt。
- 工具和写权限由 runtime 限制。
- 结果以 evidence 回到父 agent。
- 是否用于 card、PKM、schedule，由 SuperAgent 当轮动态决定。
