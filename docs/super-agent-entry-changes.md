# `codex/super-agent-entry` 分支变更分析

**基线**：`merge-base(codex/super-agent-entry, origin/main)` = `0f11647`
**规模**：48 文件，+6950 / -399 行，17 个分支独有提交（与 GitHub `main...codex/super-agent-entry` 一致）

这条分支把 App 的中央 AI 按钮从旧的"发布输入面板"改造成统一的 **Super Agent 对话入口**，并围绕它补齐能力：对话即记录、图片附件、动态 HTML 卡片、Timeline 诊断、运行模式/审批门控、上下文压缩、会话保活、沙箱克隆等。

## 功能总览

**已接线、用户可感知**
1. 主入口路由 → Super Agent 对话（`super_agent_home` 场景），按 scene 续接专属会话（§1）
2. 新对话框 UI：简化输入、工具调用过程可视化、运行模式选择器、artifact 产物预览（§1、§5）
3. `submit_record`：对话即记录，走 Facts/Card/PKM 管线，支持文本 + 图片（§2）
4. 图片附件端到端：相机/相册、导入 workspace、inline 转码 JPEG 兼容各 provider（§2）
5. `dynamic_timeline_ui`：agent 生成 HTML timeline 卡片（§3）
6. `timeline_diagnostics`：只读诊断、重试失败卡片（§4）
7. 运行模式 + 写操作审批门控：auto / confirm / read_only（§5）
8. 会话保活 + 重连：关窗后回合继续跑、重开重建中间态（§6）
9. 上下文压缩、Facts 文件层只读（§5、§6）
10. 沙箱用户克隆（§7）

**已删除**：Agentic Surface（WebView 工作台）—— 引入后从未接线，已整体移除（§9）

**易误判为新增、实则 base 已有**：Timeline 的 WebView 渲染能力、`scene`/`sceneId` 字段、`ChatDisplayItem` 展示模型（§9）

---

## 1. 主入口与对话框

### 入口路由（`0c8a769`）

`lib/main.dart` 的 `_handleAICoreButtonTap()`：旧逻辑打开 `_isInputOpen` 发布面板；新逻辑仅在 onboarding 演示（`DemoStep.tapSend`）保留旧面板，其余调 `_openSuperAgentDialog()` 用 `showGeneralDialog` 弹出 `AgentChatDialog(scene: 'super_agent_home')`。

发表入口会先调 `_latestSuperAgentSessionId()` 找回最近的 super_agent_home 会话续接（机制详见 §8）。

### 对话框 UI（`04e20be` + `795190d` + `6c3d692`）

`lib/ui/chat/widgets/agent_chat_dialog.dart`：

- **`_isSuperAgentHome` getter**（`scene == 'super_agent_home'`）区分主入口的输入/空状态 UI（居中 agent 图标 + inputHint、隐藏模式 chip 与历史按钮）。注意 `scene`/`sceneId` 字段与 `ChatDisplayItem` 展示模型在 base 上**已存在**，本分支只新增这个 getter 并复用既有模型。
- **工具调用过程可视化**（`795190d`，+519/-133）：给 `ProcessItem` 加一套渲染——`_buildProcessStatusGlyph`/`_buildProcessStatePill`（状态图标/药丸）、`_buildToolSummaryChips`/`_buildToolChip`（工具汇总 chip）、`_buildToolTraceList`（调用轨迹）、`_compactPreview`（入参/结果短预览），并对 dynamic_timeline_ui 的工具名做专门展示分支。让用户看到 agent 正在调哪些工具、进展与结果。
- **运行模式选择器 + artifact 预览**（`6c3d692`）：详见 §5。

---

## 2. 对话即记录与附件

### `submit_record`（`0c8a769`，`afe8ddf` 扩展图片）

新增 `lib/agent/skills/submit_record/submit_record_skill.dart`：把用户消息走与旧输入面板相同的本地优先管线（`submitInput` → Fact / 占位卡 / 异步 card·PKM·comment·index）。

- 入参 `content`（原文保留语言）+ 可选 `image_paths` + `reason`；`required` 为 `[]`，**允许纯图片提交**。
- 提交后经事件总线发 card-added、返回 `fact_id`。
- 注册进 `super_agent.dart`，纳入 Quick Query 排除集（写类 skill 在只读快查下禁用）。
- 系统提示界定何时用：用户要"记/存/记录"或分享生活·工作·知识片段、direct-entry 发媒体且无提问/编辑要求时才提交；纯提问、检索、编辑既有卡、意图模糊时不提交。

### 图片附件（`afe8ddf`）

核心在 `lib/data/services/chat_service.dart`：

- `_prepareChatImage()` / `_PreparedChatImage`：图片经 `MediaService.importImage` 导入 workspace 得 `relativePath`，过 `AssetSafetyService` 安检后 `base64Encode` 成当次发给 LLM 的 `ImagePart`（临时，不持久化）。
- `_buildAttachmentContext()` 注入系统提醒。**关键安全约束**：上传附件 ≠ 同意创建记录；意图模糊先描述再问；只有用户明确要存才调 `submit_record` 并原样传 `image_paths`。
- **来源支持相机 + 相册**：`_pickImage(ImageSource.camera/gallery)`，相册经 `PhotoSuggestionService.assetToXFile` 转换并留原始文件名；`_selectedImages` 缩略图列表可单张移除。
- `memex_router.dart` 透传 `images` / `imageOriginalFilenames` 给 chat_service。

### 跨平台图片编码（`45b302b` + `62dfaa3`）

`lib/data/services/llm_image_codec.dart`：`transcodeForLlm` 把 inline 给模型的图片（iOS 相册常为 HEIC）转码 JPEG、长边限 2048、自动旋转——因为 OpenAI 兼容端点（Kimi 等）拒收 HEIC（Gemini 能收）。Lifelog 原图不动。`62dfaa3` 进一步修复**已写入会话**的 provider 不安全内联图片，避免毒化重放。

### 基础提示行为转向（`afe8ddf`）

`chat_service.dart` 里**所有 chat 会话共享**的通用提示从"不确定就先问"改为 **Agentic Judgment**：低风险捕获/可逆整理直接做，只在歧义改变语义或下一步高影响时才问。与 super_agent 的 Direct Entry 提示同理念，但影响面更广。

---

## 3. 动态 Timeline UI 卡片（`795190d`）

新增 `dynamic_timeline_ui` skill（`dynamic_timeline_ui_skill.dart` + `design_pattern_library.dart`）：用户要可视化卡片/UI/仪表盘或改卡片样式时，生成**自包含、纯展示**的 HTML/CSS（禁 JS/iframe/表单/网络/外部资源/事件属性；移动优先、单根容器、内联 CSS）。工具：`recommend_/get_/list_dynamic_timeline_design_patterns`（取设计参考）→ `create_/update_dynamic_timeline_card`。

> **能力边界（易误解）**：本分支只新增"**让 agent 生成 HTML**"。Timeline 用 WebView **渲染** HTML 卡片是 base 早有的能力（`html_webview_card.dart` 自 `init project` 即存在，本分支零改动；渲染链 `timeline_screen.dart` → `native_widget_factory.dart` → `HtmlWebViewCard` 都是既有的）。一句话：**能渲染是旧的，agent 能生成才是新的。**

### 实现机制（生成 → 落库 → 渲染）

**a) 谁生成 HTML**：skill 不生成，HTML 由 LLM 按提示写出、作为 `html` 参数传入。三个 `*_design_pattern*` 工具只读取静态 `DynamicTimelineDesignPatternLibrary` 喂参考。

**b) 代码层二次过滤**：`sanitizeHtmlForTimeline` 剥 ```html 围栏、空/超 60000 字符报错、黑名单扫 `<script/iframe/object/embed/form/input/button/link/meta`/`javascript:`/`data:text/html`/`srcdoc=`、拒内联 `on*=` 事件属性。

**c) 落库但不进知识管线**：`createDynamicTimelineCardForUser` 走普通记录同套底座（`generateFactId` → `appendToDailyFactFile` 写 Fact → `safeWriteCardFile` 写卡 YAML，`status=completed`）。**关键**：只发 `CardAddedMessage`/`CardUpdatedMessage` 到 `EventBusService`（纯 UI 刷新），**不调 `submitInput`、不 publish `userInputSubmitted`**。而知识管线（card-agent/PKM/comment/索引）由 `GlobalEventBus` 的 `userInputSubmitted` 事件 fan-out 触发，所以动态卡 ❌ 不组织 PKM、❌ 不建索引、❌ 不生成 comment，✅ 只刷新显示。**副作用**：动态卡的 fact 文本不进知识库/搜索索引——事后 PKM/检索搜不到它（与 submit_record 形成对比）。

**d) `templateId` vs `factId`（会不会覆盖）**：`templateId: 'legacy_html'` 是渲染类型标签、所有动态卡共用（类比文件后缀）；卡的身份是 `factId`（`generateFactId` 每次取当天最大 `ts_N` +1）。所以 **`create` 永远新建、从不覆盖**；只有 `update_dynamic_timeline_card` 传 `card_id` 时才替换**那一张卡**内部的 `legacy_html` html（`_upsertLegacyHtmlConfig`）。

**e) `legacy_html` 内联 vs 旧"模板 id 引用"**：

| | 卡里存什么 | HTML 何时成形 |
|---|---|---|
| 旧自定义模板（`card_renderer.dart` 真模板分支） | `templateId` 指模板文件 + `data` | 渲染时 `readTemplateHtml`→`renderHtmlTemplate`→`replaceFsInHtml`，事后转成 `legacy_html` |
| 新 dynamic_timeline_ui | 直接 `legacy_html` + `data['html']`（成品） | 写卡时定型，无模板文件、无渲染步骤 |

**f) 读取展示仍经 `card_renderer` 的"透传"分支**：`hydrateCard` → `renderCard` 时，`legacy_html` 因 `isNativeCard=false` 进 else、`readTemplateHtml` 找不到模板文件返回 null，落到终端 else 仅对 data 跑 `replaceFsInData` 后**原样透传**。它**不跑** `replaceFsInHtml`，html 字段也不受 `replaceFsInData` 影响——这是动态卡 HTML 必须**完全自包含**的原因。

### 三个 skill 怎么选

没有代码 if/else 决定——LLM 依各 skill 的 `description` + `systemPrompt` 判断意图，边界模糊由 LLM 权衡。

| | `submit_record`（=旧 submit_input） | `dynamic_timeline_ui` | `manage_timeline_card`（既有） |
|---|---|---|---|
| 内容作者 | 用户（原文照录） | agent/LLM（写 HTML） | — |
| 产物 | Fact → 占位卡 → 异步管线 | `completed` 成品 HTML 卡 | 结构化改既有卡 |
| 走知识管线 | ✅ 完整 | ❌ 仅 UI 刷新（见 c） | 视操作 |
| 何时用 | 记/存/分享内容 | 要视觉卡/UI/改样式 | 编辑已有卡/PKM/设置 |

> 注：在此基础上后续新增了"渲染自检工具"（让 agent 把候选 HTML 渲染成图片自检），属于本仓库本次会话的工作，单独记录于 `docs/render-preview-tool.md`，不在本分支分析范围内。

---

## 4. Timeline 诊断（`795190d`）

新增 `timeline_diagnostics` skill：用户报告卡片/图片/UI 缺失·错误·难看·卡住·失败时，对本地 card/fact 数据与资源引用做**只读诊断**，可重试失败卡片。

- 工具：`list_recent_timeline_cards`、`inspect_timeline_card`、`inspect_timeline_card_assets`、`describe_timeline_render_path`、`retry_failed_timeline_card`。
- 边界：**看不到手机实时屏幕**；除非写/重试工具成功否则不宣称视觉问题已修复，仍需用户视觉确认；一轮诊断即总结停止，不在 diagnostics 后继续通用文件搜索。

---

## 5. 运行模式与安全门控

### 运行模式 + 写操作审批（`6c3d692`）

"类 Claude Code 权限模式"，仅作用于 super_agent_home：

- `lib/agent/run_mode/agent_run_mode.dart`：`AgentRunMode` 三档——`auto`（写工具直接执行，默认）/ `confirm`（每个写工具调用前在对话内等批准）/ `readOnly`（映射 quick-query，写类 skill/工具不给模型）。存 `AgentState.metadata['run_mode']`，偏好经 `UserStorage.getSuperAgentRunMode()` 持久化。
- `lib/agent/run_mode/agent_action_approval_service.dart`：`confirm` 下写工具先产生 `AgentActionApprovalRequest`（toolName + 人类可读 summary）等待审批；各写类 skill（dynamic_timeline_ui create/update、submit_record 等）调用前过 `gateMutatingToolCall`。
- **Artifact 预览**：写工具结果带 `metadata['artifact']`，`lib/data/model/chat_artifact.dart` 的 `ChatArtifact.fromToolMetadata` 解析后渲染产物 tile（record/html_card/card/file/system_action/insight）。

### Facts 文件层只读（`a0c18ea`）

不止靠系统提示，而是在**文件工具权限层**强制 `/Facts` 只读——agent 的 Write/Edit/Move/Remove 对 Facts 直接被拒。新记录只能走 `submit_record`。

### 单轮工具预算（`795190d`，与运行模式互补）

`super_agent.dart` 防 agent 无限探索：`_loopBudgetWarningTurns=6`（6 轮后经自定义 `SystemCallback` 注入 `_loopBudgetReminder` 提示收敛）、`_loopBudgetToolCutoffTurns=10`（10 轮后清空 `tools` 强制收尾）。

### 系统提示（`795190d`）

`prompts.dart` 新增两段：
- **Direct User Entry**：把主入口定位为 agentic workspace 而非一次性聊天框，低风险工作直接推进，分享内容走 `submit_record`，仅高风险/真歧义才确认。
- **Verification and Visual Honesty**：agent 看不到实时屏幕，视觉问题先用 `timeline_diagnostics`，禁止仅凭推断说"已修复"，诊断路径有界。

---

## 6. 上下文与会话健壮性

### 上下文压缩（`79f5522` + `22b2381`）

`lib/agent/memory/super_agent_context_compressor.dart`：包 core 的 `LLMBasedContextCompressor`（Claude Code 式定额压缩——prompt 超阈值即把旧消息摘要成快照、留最近若干条原文；阈值保持 core 默认 64k），加 Memex 专属清理：归档进 episodic memory 的消息把内联图片 base64 换成 `fs://` 占位符（归档后图片回不到模型、是死重，否则每次存 state 都重写）。Live 历史不动，图片对模型仍可见。

### 会话保活 + 重连（`32f653e`）

`lib/data/services/chat_run_registry.dart`：`ActiveChatRun` 把进行中的 agent 回合移到 service 层持有，事件进 replay buffer + broadcast。`attach` 先重放已发事件再接续 live（快照+订阅在同一同步块内，零丢失/重复）。效果：对话框关闭后回合继续跑，重开能重建"thinking"中间态（`_router.hasActiveChatRun(sessionId)`）。

---

## 7. 沙箱用户克隆（`a8187e9`）

新增 `lib/data/services/sandbox_user_clone_service.dart`，把当前 workspace 克隆成本地测试用户并切换，方便用真实数据安全测试：

- `cloneCurrentUserToLocalTestUser()`：复制 `workspace/_<userId>`，默认排除运行态目录 `_System/state_dir`、`_System/llm_calls`，返回 `SandboxUserCloneResult`。
- 配套：`settings_registry.dart` 注册、`debug_settings_page.dart` 调试入口、`personal_center_screen.dart` UI、i18n。

---

## 8. 存储结构与会话复用（深入）

> 回答：存储到底变了什么、`scene` 干嘛用、发表入口会话是否一直复用。

**数据库零改动**：`lib/db/tables.dart`（Drift）本分支不动。chat 会话不存数据库，落在 workspace 的 JSON 文件——"存储变化"指**会话 JSON 内容格式**，非 schema 迁移。

**消息 content 新增 `image_url` part（图片支持是这次才有的）**：base 上消息 content 只有文本 part；`chat_service._buildSessionUserContent` 现可追加 `{"type":"image_url","image_url":{"filePath":"<相对路径>"},"mime_type":...,"name":...}`。图片本体不进 JSON（只存路径引用），base64 仅当次发 LLM 用。会话列表对纯图片会话适配（预览 `Sent N image(s)`、标题 `Image conversation (N)`）。

**`scene`/`sceneId` 不是新字段，但"待遇"变了**：它在 base 已存在（`AgentChatDialog` 构造参数默认 `scene='assistant'`、`chat_service.sendMessage` 参数、`switch(scene)` 注入场景化系统提示）。本分支做两件事：(1) 从"用完即弃的运行时参数"变成**持久化字段**——`_createSession` 写入 `scene`/`scene_id`，`fetchChatSessions`/`fetchChatSessionDetail` 读回；(2) 新增场景值 `super_agent_home`。

**为何持久化 scene**：发表入口与老顶部入口**共用 `agentName: 'memex_agent'`**，仅靠 agentName 无法区分。`main.dart._latestSuperAgentSessionId()` 在最近 30 个会话里（按文件 mtime 倒序，`chat.dart:60`）返回第一个 `scene=='super_agent_home'` 的 session_id，找不到则 null。

**发表入口 = 一条常驻累积会话**：每次发消息续写 → mtime 刷新 → 下次又选中它 → 收敛到同一条；仅当不存在时才新建。super_agent_home 头部无"历史/新建会话"按钮，用户也没手动开新会话的入口。**副作用**：会话无限增长、token 越堆越多——`_loopBudget*` 只限单轮工具次数、不裁历史长度；现由 §6 的上下文压缩缓解。

**兼容性**：均为向后兼容追加——老会话无 `scene` 读出 null（`as String?` 容错），老消息无 `image_url` part 照常按文本处理，无 schema 迁移。

---

## 9. 已删除与易误判

### 已删除：Agentic Surface（`a2a2430`）

`795190d` 曾引入 WebView 工作台（`agentic_surface_service.dart` + `agentic_surface_screen.dart`：意图识别 `looksLikeAgenticSurfaceIntent` → `createOrUpdateSurface` 写 HTML → `AgenticSurfaceScreen` 用 webview_flutter + `MemexBridge` 渲染）。但它**从未接线**（无实例化点、无调用点、无路由）。`a2a2430` 把 service + screen + 单测整体删除——两文件现已不存在。

### 易误判为"新增"、实则 base 已有

- **Timeline WebView 渲染 HTML 卡片**：`html_webview_card.dart` 及渲染链自 `init project` 即存在，本分支零改动。新增的只是"生成 HTML 的 skill"。
- **`scene`/`sceneId` 字段、`ChatDisplayItem` 展示模型**：base 已存在；本分支只新增 `_isSuperAgentHome` getter 与持久化 scene，复用既有模型（详见 §1、§8）。

---

## 10. 测试覆盖

新增（`--diff-filter=A` 核实）：
- skill/服务：`submit_record_skill_test`、`dynamic_timeline_ui_skill_test`、`timeline_diagnostics_skill_test`、`sandbox_user_clone_service_test`
- 第二批子系统：`run_mode/agent_action_approval_service_test`、`memory/super_agent_context_compressor_test`、`model/chat_artifact_test`、`services/chat_run_registry_test`、`services/llm_image_codec_test`

更新：`test/ui/chat/widgets/agent_chat_dialog_test.dart`
删除：`test/data/services/agentic_surface_service_test.dart`（随 §9 子系统删除）

---

## 11. Super Agent 全貌（技能、工具、激活策略）

`SuperAgent.createAgent()`（`lib/agent/super_agent/super_agent.dart`）在普通模式下默认装配以下 8 个技能，默认 `forceActivate=false`，仅在 `scene` 场景映射中按需强制激活。

### 技能清单与工具

| Skill | 主要职责 | Tools（按名称） | 备注 |
|---|---|---|---|
| `submit_record` | 判定用户输入是否应进入记录主链路；写入 Facts/Card/PKM 流程 | `submit_record` | 底层最终走 `submit_input_endpoint.submitInput` |
| `update_knowledge_insight` | 生成/更新知识洞见卡 | `get_exists_knowledge_insight_cards`、`save_knowledge_insight_cards`、`delete_knowledge_insight_card`、`delete_knowledge_insight_tags`、`get_available_insight_card_templates`、`get_user_activity_stats` | 同步保存 insight 卡 |
| `manage_timeline_card` | 读取/保存 timeline 卡元信息（标题、tags、template/data） | `get_card_metadata`、`save_timeline_card` | 新建/更新现有卡片 |
| `dynamic_timeline_ui` | 生成/更新展示型 HTML 卡片（timeline 上的可视化卡） | `recommend_dynamic_timeline_design_patterns`、`get_dynamic_timeline_design_pattern`、`list_dynamic_timeline_design_patterns`、`preview_dynamic_timeline_card_render`、`create_dynamic_timeline_card`、`update_dynamic_timeline_card` | 生成 HTML，不走知识归档与检索链路 |
| `timeline_diagnostics` | 卡片/图片/渲染路径诊断与失败重试 | `list_recent_timeline_cards`、`inspect_timeline_card`、`inspect_timeline_card_assets`、`describe_timeline_render_path`、`retry_failed_timeline_card` | 只读为主；重试时写回正常异步 pipeline |
| `manage_pkm` | PKM 组织与卡片洞见更新 | `update_timeline_card_insight`、`skip_pkm_organization` | `workingDirectory` 传 `'/PKM'` |
| `manage_calendar_and_reminders` | 本地提醒与日历动作管理 | `create_calendar_event`、`create_reminder`、`get_recent_actions`、`cancel_action` | 需要明确的时态/时间解析 |
| `ask_clarification` | 提需求确认 / 高频歧义打断点问题 | `create_clarification_request`、`get_pending_clarification_requests`、`get_recent_clarification_requests` | 只用于高影响或关键歧义 |

### 非技能工具（`SuperAgent` 自带）

常规模式 `quickQuery=false` 时，`allTools` 包含：
- 文件操作：`LS`、`Glob`、`Grep`、`Read`、`BatchRead`、`Write`、`Move`、`Remove`、`Edit`
- 事件/上下文：`search_workspace_event_logs`、`getCurrentTime`、`get_pkm_overview`
- Memory 管理：`append_memories`

其中 `/Facts` 目录始终强制只读；`Facts/assets` 在非 quickQuery 下可写。  
（注：`quickQuery` 白名单目前写的是 `search_event_logs`，而真实工具名为 `search_workspace_event_logs`，实际过滤是否生效取决于这两个名字的对齐情况。）

### 激活策略

1. **默认激活**  
   上述 8 个技能都注册，但都不是永久 `forceActivate`（默认 false），让模型按场景和意图选择。

2. **Quick Query（只读）模式**  
   `quickQuery=true` 时执行工具过滤和技能过滤：只保留只读文件工具（`_readOnlyToolNames`），且从技能中剔除  
   `submit_record`、`manage_timeline_card`、`dynamic_timeline_ui`、`timeline_diagnostics`、`ask_clarification`。  
   剩余可用技能一般是：
   - `update_knowledge_insight`
   - `manage_pkm`
   - `manage_calendar_and_reminders`

3. **强制激活（按 `scene`）**  
   `chat_service.dart` 在构建 agent 时按场景传 `forceActiveSkills`：
   - `scene == assistant_timeline_card_detail`：`manage_timeline_card`、`manage_pkm` 强制激活  
   - `scene == insight_card_chat`：`update_knowledge_insight` 强制激活  
   - `scene == super_agent_home`：无额外强制激活，仅靠模型自由选择  

### 快照结论

- **能力覆盖面**：Super Agent 现在是“统一入口 + 多技能路由”模型，能同时做记录、编辑、可视化、诊断、日历动作与澄清提问。  
- **用户体验差异**：不再是单一 `InputSheet` 直发，而是主入口先进入 `super_agent_home` 对话，再按 intent 落到对应 skill。  
- **可追踪性**：每个 skill 的工具名都在当前文档中一一列出，便于后续调试时快速映射“为什么模型没走某条链路”。 

### 额外补充：Super Agent 还依赖的非 Skill 工具与运行机制

#### 1) 除 skill 自带工具外的“底层工具”

Super Agent 的 `allTools` 在 `super_agent.dart` 里还有一层文件/系统工具，按名称如下：

- 文件系统工具（`FileToolFactory`）：
  - `LS`
  - `Glob`
  - `Grep`
  - `Read`
  - `BatchRead`
  - `Write`
  - `Move`
  - `Remove`
  - `Edit`
- 事件/环境工具：
  - `search_workspace_event_logs`
  - `getCurrentTime`
  - `get_pkm_overview`
- Memory 管理工具（非 read-only 场景）：
  - `append_memories`

说明：这些工具对模型可见并与 skill 工具一起被放入同一轮 agent tool 集合（quickQuery 会做过滤）。

#### 2) 是否有子 agent

目前 `SuperAgent.createAgent()` 里创建 `StatefulAgent` 时是：

- `disableSubAgents: true`

所以当前入口是**单一 agent**，不主动启动子 agent；它只调度自己的技能+工具链。  
（`chat_service` 在接入普通 chat 时确实有 custom agent 分支，但那是“换 agent 类型”，不是 Super Agent 内部再拉子 agent。）

#### 3) 上下文压缩是怎么做的

有，且是 Super Agent 独有的包装层。

- 压缩器：`SuperAgentContextCompressor`（`lib/agent/memory/super_agent_context_compressor.dart`）  
- 触发位置：在 `StatefulAgent` 构造时通过 `compressor: SuperAgentContextCompressor(...)` 挂入（`super_agent.dart`）  
- 参数：`totalTokenThreshold: 64000`，`keepRecentMessageSize: 10`（固定配额压缩，向 core 的 `LLMBasedContextCompressor` 对齐）  
- 逻辑：
  1. 先走 core 的固定配额压缩逻辑：当 prompt 超阈值时把旧消息归档到 `episodicMemories`，保留最近 10 条原文消息。
  2. 再做 Memex 清理：`stripArchivedImageBytes` 把归档消息里的 `ImagePart` 全部换成文本占位符（`[archived image attachment: fs://...]`）。
  3. `fs://` 路径来源于 `chat_service.dart` 在每轮构造 `UserMessage` 时写入的 `metadata['image_fs_paths']`，这样可避免把 base64 图片反复写入 agent state。

#### 4) 还可观察到的配套机制（非工具本体）

- **附件走一条链路**：聊天图片先 `importImage` 入 workspace（`relativePath`），同时按 provider 兼容性 inline 编码（`llm_image_codec`），并写入 `image_fs_paths` 元数据。  
- **执行中止保护**：高危写操作会走 `gateMutatingToolCall`，在 confirm 模式下要用户在 UI 里逐个批准（见 run mode 机制）。  
- **循环预算**：同一用户回合执行工具轮次到达阈值后会给系统提醒，达到上限会强制清空 tools，强制收束。
