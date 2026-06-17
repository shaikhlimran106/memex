# Memex SuperAgent Harness Engineering 技术方案

> 背景：旧 `submit_input` 管道里，多个专用 agent 通过事件订阅、专用 prompt、定制工具、完成校验和重试循环形成了事实上的 harness。迁移到 SuperAgent 后，能力集中到一个对话式 agent loop 中，灵活性提升，但部分 workflow 的确定性、完成保证、结构健康提醒和数据语义边界被削弱。
>
> 本方案参考 Codex 的 super-agent loop 设计：模型负责判断和提出下一步动作，harness 负责构造上下文、控制工具可见性、执行权限检查、记录工具结果、校验 workflow 是否完成、必要时注入恢复提醒并继续 loop。

## 一、设计目标

Memex SuperAgent 不应只是「一个大 prompt + 一组并列 skills」。理想形态应为：

```text
SuperAgent = reasoning core
Harness = workflow control plane
Tools = enforced side-effect boundary
Validators = completion truth source
Hooks = dynamic correction layer
Context builder = semantic input compiler
Observability = improvement loop
```

核心目标：

- 恢复旧链路中有价值的 workflow 完成保证。
- 保留 SuperAgent 多轮对话和统一入口的灵活性。
- 把关键约束从 prompt 下沉到代码级 harness。
- 让工具调用、完成状态、失败原因和恢复动作可观测、可评估。
- 减少多 skill 并列导致的注意力稀释和误触发。
- 让 Memex 的运行环境、数据结构、诊断入口和长期规则对 agent 可读、可验证、可维护。

## 二、总体架构

建议将 SuperAgent 外层改造成如下控制面：

```text
User/Input Event
  -> TurnContext Builder
  -> Intent / Workflow Planner
  -> Context & Skill Injection
  -> SuperAgent Model Loop
  -> Tool Router / Tool Runtime
  -> Workflow Completion Validators
  -> Recovery / Reminder Loop
  -> Persisted State + Observability
```

关键原则：

- 模型可以建议动作，但 harness 决定哪些工具可见、哪些工具能执行、何时继续、何时结束。
- 每个重要业务 workflow 都应有代码级完成条件，不靠模型自己声明完成。
- `<system-reminder>` 仍有价值，但它应作为恢复和引导机制，不应作为唯一约束。
- 工具必须返回结构化 evidence，供 validator 判定真实完成状态。

## 三、TurnContext：统一输入语义

每一轮进入 SuperAgent 前，harness 先构造标准化 `TurnContext`，避免时间、地点、附件、引用、workflow 状态散落在 user message 文本中。

建议字段：

```text
turn_id
session_id
user_id
input_kind
user_message_time
current_local_time
location_context
attachment_context
referenced_card_ids
referenced_fact_ids
active_workflow
permission_mode
loop_budget
completion_contract
already_completed_steps
```

`input_kind` 建议至少覆盖：

- `chat`
- `capture`
- `card_edit`
- `comment_reply`
- `manual_reprocess`
- `scheduled_job`
- `quick_query`
- `repair`

时间语义应固定为两条独立锚点：

- `User Message Time`：用户原始输入时间，重处理旧消息时保持不变。
- `Current Local Time`：当前处理时间，重处理时代表现在。

地点语义也应固定：

- 捕获时地点：用于判断输入是否描述当前发生的事情。
- 卡片实际地点：用于 card/comment/schedule 后续流程。
- 用户标记地点：raw input 中明确出现、接近用户已知地点时才使用。

## 四、Workflow Contract：恢复完成保证

SuperAgent 应根据输入进入具体 workflow，每个 workflow 都有 `WorkflowContract`。

### 4.1 新捕获 workflow

```text
workflow: capture_to_memory

required_steps:
  - prepare_assets
  - save_timeline_card
  - organize_pkm_or_skip
  - update_card_insight_or_skip
  - trigger_comment_if_enabled

conditional_steps:
  - schedule_aggregation if schedule intent detected
  - clarification_request if high-value ambiguity detected

validators:
  - card file exists
  - persisted fact_id matches
  - card status completed
  - card has title
  - card has ui_configs
  - PKM write contains current fact_id, or explicit skip reason exists
  - insight exists, or explicit skip reason exists
```

这相当于把旧 `card_agent.inspectCardRunCompletion` 和 `pkm_agent.inspectPkmRunCompletion` 升级为通用机制。

### 4.2 卡片修复 workflow

```text
workflow: card_repair

required_steps:
  - identify_target_card
  - inspect_original_input_and_current_card
  - update_card_if_needed

validators:
  - target card resolved
  - original input inspected
  - save_timeline_card called if mutation needed
  - persisted card still has matching fact_id
```

### 4.3 PKM 维护 workflow

```text
workflow: pkm_maintenance

required_steps:
  - inspect target files
  - perform requested move/edit/split/merge
  - preserve fact_id references

validators:
  - target files exist or explicit no-op reason exists
  - edits occurred inside /PKM only
  - fact_id references were not dropped unexpectedly
```

### 4.4 日程聚合 workflow

```text
workflow: schedule_aggregation

required_steps:
  - load canonical schedule_state
  - apply necessary pending item changes
  - set_presentation once

validators:
  - no duplicate pending items
  - no unsupported mutation outside schedule service
  - set_presentation called at most once unless repair mode
```

### 4.5 评论 workflow

```text
workflow: character_comment

required_steps:
  - load card fact and timestamp
  - load character context
  - save or explicitly skip comment

validators:
  - comment saved through SaveComment, or SkipComment called when allowed
  - entry time comes from card timestamp
  - location comes from card address or capture location when available
```

## 五、Turn-stop Hook：阻止过早结束

借鉴 Codex 的 stop hook：SuperAgent 每次准备结束时，harness 运行 `turn_stop_hook`。

如果 workflow 未完成，不允许自然结束，而是将缺失项注入下一轮：

```text
<system-reminder>
The workflow is incomplete.

Missing required steps:
- save_timeline_card
- update_timeline_card_insight

You must complete these before finalizing this turn.
</system-reminder>
```

然后继续 model loop。

该机制比在 system prompt 中写「必须完成」更强，因为它发生在模型每次试图收尾时。

## 六、Tool Router：按 workflow 动态暴露工具

不要让 SuperAgent 永远看到所有工具。每轮由 harness 根据 `active_workflow`、权限、输入类型和上下文构造工具可见性。

建议策略：

```text
capture_to_memory:
  visible:
    - get_card_metadata
    - save_timeline_card
    - get_pkm_overview
    - Read / Grep / LS within /PKM
    - Write / Edit within /PKM
    - update_timeline_card_insight
    - create_clarification_request
    - schedule_aggregation tools if schedule intent detected

quick_query:
  visible:
    - read-only search tools
    - get_pkm_overview
    - timeline search / diagnostics read-only
  hidden:
    - save_timeline_card
    - Write / Edit / Move / Remove
    - update_memory

card_repair:
  visible:
    - timeline_diagnostics
    - get_card_metadata
    - save_timeline_card
    - read original input

comment_reply:
  visible:
    - SaveComment
    - SkipComment
    - character memory read tools
  hidden:
    - PKM write tools
    - schedule mutation tools

settings_update:
  visible:
    - settings tools
  guard:
    - approval required for high-impact setting changes
```

收益：

- 减少 skill 互相抢注意力。
- 降低误触发写入工具概率。
- 让 prompt 更短、更聚焦。
- 让不同 workflow 的权限边界更明确。

## 七、Tool Runtime：关键约束下沉到工具层

### 7.1 `save_timeline_card`

运行时约束：

- 模型不得自行编造新 `fact_id`。
- 新建卡时由系统分配或确认 `fact_id`。
- 编辑卡时必须验证目标卡存在。
- `assets` 必须来自当前输入或已存在卡片。
- `content_creation_date` 解析失败时应返回 warning 或 fallback evidence。
- 保存后返回结构化结果。

建议工具结果：

```json
{
  "success": true,
  "fact_id": "2026/06/15.md#ts_1",
  "card_path": "...",
  "status": "completed",
  "title_present": true,
  "ui_configs_present": true,
  "timestamp": 1781510400,
  "warnings": []
}
```

### 7.2 PKM 文件工具

恢复旧 `pkm_agent` 专用 Read 工具里的结构健康提醒，并做成通用 decorator。

检查项：

- 文件超过 1000 行：提示关注结构合理性。
- 文件超过 2000 行：提示必须拆分或调整。
- 目录里过多只有 0/1 个 `fact_id` 的碎片文件。
- 文件名包含日期。
- 文件在最近 5 次输入中被频繁编辑。

这些提醒应由工具结果自动附加，而不是依赖模型主动检查。

### 7.3 `update_timeline_card_insight`

运行时约束：

- `fact_id` 必须对应真实 card。
- `related_fact_ids` 必须来自真实 Facts/PKM 引用。
- 不允许模型猜测 historical fact id。
- insight 更新结果必须进入 workflow evidence。

### 7.4 `schedule_aggregation`

运行时约束：

- 所有状态读写必须经过 canonical schedule service。
- `set_presentation` 默认一轮只允许一次。
- 如果无 schedule state 变化，工具应返回 no-op evidence。
- 自动聚合和手动刷新应使用不同 run context。

### 7.5 `create_clarification_request`

运行时约束：

- 必须有 `dedupe_key`。
- 必须有 `evidence_fact_ids`。
- `proposed_memory` 只能作为待确认内容，不能直接写长期记忆。
- 重复问题应返回 existing request，而不是新建。

## 八、Hooks：动态约束和恢复层

建议实现四类 hook。

### 8.1 `input_inspection_hook`

职责：

- 识别 intent。
- 选择 workflow。
- 提取 card/fact 目标。
- 判断是否需要 schedule/clarification/comment 下游。
- 生成 `WorkflowContract`。

### 8.2 `pre_tool_use_hook`

职责：

- 校验工具参数。
- 阻止越权写入。
- 对 destructive / broad rewrite / memory mutation 做 approval gating。
- 修正明显错误参数，如相对路径、错误 fact id 格式。

### 8.3 `post_tool_use_hook`

职责：

- 解析工具结果。
- 更新 workflow state。
- 记录 completion evidence。
- 检测失败并生成下一步 recovery reminder。

### 8.4 `turn_stop_hook`

职责：

- 检查 workflow 是否完整。
- 未完成则阻止结束并继续 loop。
- 超过 retry budget 后进入 graceful degradation。
- 输出用户可理解的失败原因，同时记录机器可读 failure evidence。

## 九、Loop Budget：从轮次预算升级为阶段预算

当前通用 loop budget 容易出现两个问题：

- 复杂 workflow 还没完成就被切断。
- 单一环节失败导致模型继续无效探索。

建议改成 workflow-aware budget：

```text
capture_to_memory:
  card_save: max 3 attempts
  pkm_organization: max 3 attempts
  insight_update: max 2 attempts
  comment_trigger: max 1 attempt
  total_tool_rounds: max 12

quick_query:
  search_rounds: max 4
  synthesis_rounds: max 1

card_repair:
  diagnose_rounds: max 3
  write_rounds: max 2

schedule_aggregation:
  state_read_rounds: max 1
  mutation_rounds: max 3
  presentation_rounds: max 1
```

超预算时不要简单清空 tools，而应根据当前缺失项生成明确终止状态：

```text
workflow_status: failed
failure_type: validator_exhausted
missing_requirements:
  - updated_timeline_card_insight
last_successful_step:
  - save_timeline_card
```

## 十、Context Strategy：按需注入

不要把所有 skill 和所有上下文都塞进 prompt。

建议策略：

- 默认只注入 SuperAgent 核心职责和当前 workflow contract。
- 新 capture workflow 自动注入 card + PKM + insight 的最小必要说明。
- 用户显式涉及 PKM 时才注入完整 PKM 维护规则。
- 视觉修复时注入 timeline diagnostics 规则。
- comment workflow 只注入角色 persona、已有评论、card fact、entry time。
- 大型 PKM tree 通过 `get_pkm_overview` 按需读取，不直接进入初始 prompt。
- 附件 context 分为 `metadata`、`ocr`、`visual_summary`、`raw_asset_ref`，让工具按需读取。

## 十一、Asset Harness：确定性附件预处理

附件理解不应完全依赖 SuperAgent 视觉能力。

建议恢复并扩展 deterministic asset preprocessor：

- 图片 EXIF 读取。
- GPS reverse geocode。
- OCR。
- 音频转写。
- 文档文本抽取。
- 图片视觉摘要。
- asset sidecar 持久化。
- FTS indexing。

SuperAgent 输入中应看到结构化 attachment context：

```text
Asset:
  ref: fs://...
  type: image
  capture_time: ...
  gps: ...
  address: ...
  nearest_user_location: ...
  ocr_text: ...
  visual_summary: ...
```

这样可以同时保证：

- 卡片生成能使用视觉内容。
- PKM/FTS 能搜索 OCR。
- 评论和 insight 能引用稳定的附件分析结果。
- 重处理旧输入时语义稳定。

## 十二、Structured Clarification Harness

不建议让 SuperAgent 随口问澄清问题。应恢复结构化澄清生命周期。

工具参数：

```text
question
response_type
options
entity_type
entity_label
evidence_fact_ids
proposed_memory
resolution_target
dedupe_key
confidence
impact
expires_in_days
```

harness 负责：

- 去重。
- 过期。
- 一键回复。
- 回复后触发 memory/card 更新。
- 生成 timeline clarification card。
- 把 resolution evidence 写回长期记忆。

SuperAgent 可以决定是否需要澄清，但澄清请求的创建、展示、去重、解析和沉淀应由 harness 管。

## 十三、Observability：workflow evidence 优先

每次 SuperAgent 执行 workflow，都应记录：

- `workflow_id`
- `workflow_type`
- `active_contract`
- `input_kind`
- `tool_calls`
- `validator_results`
- `missing_requirements`
- `retry_count`
- `loop_budget_state`
- `final_status`
- `failure_reason`
- `user_visible_result`
- `model_token_usage`
- `tool_latency`
- `asset_processing_latency`

这些数据应可用于：

- 单次问题排查。
- 批量重处理。
- workflow eval。
- prompt/tool/harness 迭代。

## 十四、Evals：用完成率衡量 SuperAgent

SuperAgent 的质量不应只看聊天自然度。Memex 应该建立 workflow eval。

核心指标：

- 新捕获输入 card 创建成功率。
- card `fact_id` 一致率。
- card `title` / `ui_configs` 完整率。
- PKM 写入包含当前 `fact_id` 的比例。
- insight 自动生成率。
- comment 自动触发率。
- schedule intent recall / precision。
- clarification dedupe 准确率。
- OCR / EXIF / GPS 入库成功率。
- loop 超预算率。
- 重处理成功率。

这些指标比「模型回答看起来不错」更能反映 SuperAgent 是否真正可靠。

## 十五、Agent-legible Memex Environment

OpenAI harness engineering 的一个核心经验是：agent 在运行时无法发现的信息，对它来说等于不存在。Memex 要提升 SuperAgent 能力，不能只提升模型或 prompt，还要把产品环境改造成 agent 可读环境。

建议为 Memex 建立一组稳定、只读优先的诊断入口：

```text
timeline_diagnostics:
  - search_timeline_cards
  - inspect_timeline_card
  - inspect_original_fact
  - inspect_card_render_inputs
  - inspect_card_comments

pkm_diagnostics:
  - get_pkm_overview
  - inspect_pkm_file_health
  - find_fact_references
  - find_fragmented_files

schedule_diagnostics:
  - get_schedule_state
  - inspect_schedule_candidates
  - explain_schedule_mutation

asset_diagnostics:
  - inspect_asset_metadata
  - inspect_asset_ocr
  - inspect_asset_visual_summary
  - inspect_asset_indexing_status

workflow_diagnostics:
  - inspect_workflow_state
  - inspect_completion_evidence
  - inspect_failed_requirements
  - inspect_retry_history
```

这些入口的目标不是给用户看，而是让 SuperAgent 可以稳定定位问题、解释状态、验证修复。

设计要求：

- 每个诊断工具返回结构化 JSON，同时附带简短人类可读摘要。
- 不要求 agent 反向读 Cards/PKM/Facts 的底层文件格式来猜业务状态。
- 诊断工具应明确区分 raw input、card fact、render input、PKM evidence、comment evidence。
- 对视觉/UI 问题，必须区分「本地数据已检查」和「真实视觉表面已验证」。
- 对每个 workflow，提供一条 `inspect_workflow_state` 入口，让 agent 知道当前完成到哪一步。

这会显著降低 SuperAgent 在复杂任务中的搜索成本和误判率。

## 十六、Source-of-truth Docs：把规则变成可维护记录系统

另一个关键经验是：不要把所有规则塞进一个巨大 prompt。Memex 应把 agent 规则拆成结构化、可发现、可维护的 docs。

建议 docs 结构：

```text
docs/
  agent/
    index.md
    superagent-harness-engineering-plan.md
    workflows/
      capture_to_memory.md
      card_repair.md
      pkm_organization.md
      schedule_aggregation.md
      character_comment.md
      clarification.md
    invariants/
      timeline_card_invariants.md
      pkm_file_health_invariants.md
      asset_processing_invariants.md
      memory_invariants.md
    evals/
      workflow_eval_matrix.md
      failure_taxonomy.md
    runbooks/
      reprocess_failed_capture.md
      debug_missing_insight.md
      debug_schedule_duplication.md
      debug_comment_context.md
```

SuperAgent prompt 只应保留短地图：

```text
If the current task is capture-related, load workflow contract capture_to_memory.
If the task is PKM-related, load pkm_organization rules.
If a workflow validator fails, inspect failure_taxonomy and runbook.
```

这样可以实现渐进式披露：

- 默认上下文短。
- 任务相关规则按需进入上下文。
- 规则有文件边界、所有权和更新位置。
- 旧规则可以被发现和清理。

## 十七、Mechanical Invariants over Prompt Rules

重要约束应尽量从 prompt 升级为机械不变量。分类建议如下：

```text
soft guidance:
  - 写作语气
  - insight 表达风格
  - card title 审美偏好

tool schema validation:
  - fact_id 格式
  - required fields
  - enum values
  - path scope

runtime enforcement:
  - Facts 不可被通用写工具修改
  - PKM 写入必须在 /PKM 下
  - save_timeline_card 不能编造新 fact_id
  - schedule mutation 必须经过 schedule service

workflow validator:
  - card file exists
  - status completed
  - PKM write contains fact_id
  - insight updated or explicit skip

background linter / sweeper:
  - PKM 文件超过行数阈值
  - 目录碎片化
  - 旧 OCR 缺失
  - orphan clarification requests
  - schedule duplicate candidates
```

升级规则：

- 同一类错误重复出现 2 到 3 次，就不再只加 prompt。
- 如果错误能通过参数校验阻止，放进 tool schema 或 pre-tool hook。
- 如果错误只能在执行后判断，放进 post-tool hook 或 workflow validator。
- 如果错误是长期结构腐化，放进后台 linter/sweeper。
- 如果错误需要人类品味判断，先文档化，再收集案例，最后抽象成 eval 或 lint。

这能避免「提示越来越长，但可靠性没有本质提升」的问题。

## 十八、Garbage Collection：持续清理 agent 残渣

长期运行的 SuperAgent 会复制系统中已有模式，包括坏模式。Memex 需要周期性的垃圾回收机制。

建议后台任务：

```text
daily:
  - scan failed workflows
  - scan missing OCR / EXIF / GPS sidecars
  - scan cards without insight
  - scan comments with missing context

weekly:
  - scan PKM fragmentation
  - scan oversized PKM files
  - scan duplicated schedule items
  - scan stale clarification requests
  - scan stale agent docs

monthly:
  - update workflow eval matrix
  - review top failure categories
  - promote repeated prompt reminders into mechanical invariants
  - archive obsolete docs and rules
```

垃圾回收输出不一定要自动修改用户内容，可以先生成 repair candidates：

```text
repair_candidate:
  type: missing_card_insight
  affected_fact_id: ...
  evidence: ...
  suggested_workflow: reprocess_pkm_insight
  risk_level: low
```

这样 SuperAgent 不只是在单轮里变强，而是整个 Memex 环境会持续变得更适合 agent 工作。

## 十九、Human Attention as Scarce Resource

Codex harness engineering 的底层判断是：真正稀缺的是人类注意力。Memex 也应按这个原则设计。

建议：

- 低风险、可回滚、可验证的工作自动完成。
- 高风险、不可逆、用户敏感的工作请求确认。
- 用户不应该被要求理解内部 workflow 失败细节。
- 失败时应给出简短用户说明，同时保存完整机器 evidence。
- 重复失败不应反复打扰用户，而应进入 failure taxonomy 和后台修复队列。

对应 autonomy 分级：

```text
autonomous:
  - save new timeline card
  - generate insight
  - run OCR / EXIF indexing
  - create low-risk comment when user enabled character comments

approval-gated:
  - delete card
  - broad PKM restructure
  - overwrite user settings
  - merge duplicate schedule items with ambiguity

draft-only:
  - inferred long-term memory from ambiguous input
  - sensitive relationship/health/finance conclusions
  - clarification proposed memory before user answers
```

## 二十、推荐落地顺序

1. 实现 `WorkflowContract` + `CompletionValidator`，先覆盖 `save_timeline_card`、PKM 写入、insight 更新。
2. 实现 `turn_stop_hook`，让 workflow 未完成时不能自然结束。
3. 实现 workflow-aware `ToolRouter`，按任务动态暴露工具。
4. 把旧 `pkm_agent` 文件健康提醒迁移成 PKM tool decorator。
5. 实现 asset preprocessor，恢复 OCR / EXIF / GPS / sidecar / indexing。
6. 恢复 structured clarification workflow。
7. 补 schedule aggregation contract 和 `set_presentation` 单次约束。
8. 建 workflow observability 和 eval dashboard。
9. 建 agent-readable diagnostics，让 SuperAgent 不再反向猜底层文件格式。
10. 建 source-of-truth docs 和 doc-gardening 流程。
11. 将重复失败的 prompt reminders 升级为机械不变量。
12. 建后台 garbage collection，持续清理 agent 残渣。

## 二十一、最终判断

Codex 的启发是：super-agent 能力不是靠无限扩大 prompt 获得的，而是靠 harness 把模型包在一个可控运行时里。

对 Memex 来说，最关键的升级不是再写更多「你必须」类提示，而是把旧专用 agent 链路中已经证明有效的机制产品化：

- 任务类型识别。
- 动态工具暴露。
- 代码级完成校验。
- 未完成时自动 recovery。
- 工具层权限和业务规则。
- 附件确定性预处理。
- 结构化澄清。
- workflow 级可观测性和 eval。
- agent-readable diagnostics。
- source-of-truth docs。
- 机械不变量。
- 周期性垃圾回收。

这样才能同时获得两类收益：SuperAgent 的统一入口和多轮智能，以及旧 agent 管道的确定性和可靠性。
