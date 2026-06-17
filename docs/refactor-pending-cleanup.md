# 重构待清理清单：SuperAgent 捕获合并 + 卡片自包含化

> 背景：在「把 submit_input 提交流程合并进 SuperAgent 对话入口、卡片通过 `card.fact` + `card.assets` 自包含」的重构过程中，为避免中途反复改动同一文件，有若干现已失效/遗留的代码被**有意保留**。计划在整个重构落定后统一清理。本文件记录这些待清理点，实施时逐条核对。

## 待清理项

### 1. `extractFactContentFromFile` 中为 FTS 服务的 enrichment
`lib/data/services/file_system_service.dart`

该方法仍会读取 `.analysis.txt` / `.ocr.txt` sidecar 构建 `assetAnalyses` / `assetOcrTexts`。card_fts 已不再消费它们（现改为索引 `card.fact`）。

> 注意：异步 agent 管道里 card_agent / pkm_agent 已不再被触发（见第 6 项），comment_agent 也已停止消费它（见第 8 项），`update_timeline_card_insight` 也改为校验卡片存在、不再读 Facts（Phase 3 加固）。当前实际仍调用该方法读 analysis/OCR 的，主要是迁移逻辑与少数历史路径，**裁剪前需再次确认剩余消费者**。

### 2. `_safeWriteCardFileInternal` 的 afterMap enrichment
`lib/data/services/file_system_service.dart`（约 527–543 行）

每次写卡片都会调用 `extractFactContentFromFile` 来拼 `content` / `asset_analyses` / `asset_ocr` 三个字段塞进 afterMap。FTS handler 现在读的是 `doc['fact']`，已不消费这些字段——这成了**每次写卡都白做的一次文件 IO**。

可去掉这段 enrichment，让 afterMap 直接用 `data.toJson()`。

### 3. 重复的标记解析正则
`extractAssetsAndRawText`（`lib/data/services/card_renderer.dart`）和 `_splitFactAndAssets`（`lib/data/repositories/migrate_cards_fact_assets.dart`）都在解析 `![image](fs://…)` / `[audio](fs://…)` 标记。可抽一个共享工具函数。

### 4. 孤儿 skill `SystemActionSkill`
`lib/agent/skills/manage_system_action/`（skill 名 `manage_calendar_and_reminders`）

已从 SuperAgent 技能列表移除（被 `ScheduleAggregationSkill` 取代）。代码仍在，但**已无任何使用者**。决策：删除，或保留以备后续重新接线。

### 5. 迁移逻辑本身
`lib/data/repositories/migrate_cards_fact_assets.dart` 及其在 `memex_router._init()` 中的调用。

待所有安装都跑过一遍迁移后（若干发布周期之后），迁移逻辑与 `_System/migration_state.json` 标记即可退役。

### 6. 旧捕获管道的订阅已删 → handler / agent 成为孤儿
`memex_router._registerEventSubscriptions()` 中 `userInputSubmitted` 原有 5 个订阅，现已删到只剩 `comment_agent`。被删的 4 个：`analyze_assets` / `card_agent` / `pkm_agent` / `post_card_router`。

它们对应的 handler 与 agent 代码仍在但**已无触发入口**（除下方第 7 项的旧再发布路径外）：
- `task_handlers/analyze_assets_handler.dart`、`card_agent_handler.dart`、`pkm_agent_handler.dart`、`post_card_router_handler.dart`
- `agent/card_agent/`、`agent/pkm_agent/`、`agent/post_card_router_agent/`、`built_in_tools/asset_analysis_tool.dart`

> 退役前需确认：PKM 组织、读图分析(.analysis.txt/.ocr.txt 生成)、洞察等能力是否要在新流程下以别的方式保留，还是彻底废弃。这影响第 1 项里"异步管道仍消费 extractFactContentFromFile"的前提——card_agent/pkm_agent 现已不再被触发。
>
> **例外：MemoryAgent 已重新接线，不在孤儿之列。** 旧链路里 MemoryAgent 由 `pkm_agent_handler:99` 的 `enqueueFact` 触发，随 pkm 管道一起断了。现已改为：`save_timeline_card` 新建卡成功后直接 `MemorySyncService.instance.enqueueFact`（攒批 5 条 → MemoryAgent 批处理筛选 → 写 memory.json），用户记忆自动累积已恢复。注意 `pkm_agent_handler:99` 那个旧 `enqueueFact` 调用现在是死代码（随 pkm_agent_handler 一起孤儿），真正生效的入队在 `timeline_card_skill`。

### 7. retry / reprocess 的卡片再生成已静默失效
`lib/data/repositories/retry_failed_cards.dart`（:125）、`lib/data/repositories/reprocess_pending_cards.dart`（:59）仍通过再发布 `userInputSubmitted` 来"重跑管道重生成卡片"，但管道订阅已删（第 6 项），现在再发该事件只会触发 comment_agent，**卡片再生成不再发生**。

新流程下卡片由 SuperAgent 的 save_timeline_card 直接写成 completed，不再有 processing/failed 占位卡需要重试（除历史遗留数据）。这两个入口需在旧管道整体退役时重新设计语义或下线。

### 8. comment_agent 对 asset 分析的 enrichment 对新卡失效
`lib/data/repositories/post_comment.dart`（:218-233）`processAICommentReply` 仍会 `extractFactContentFromFile` 读 Facts + `.analysis.txt` 拼视觉上下文。新流程下 chat 捕获的卡没有 Facts 文件、也没有 analysis sidecar，这段返回空——评论 agent 改为仅靠 `combined_text`（即 `card.fact`，其中已含图片内容描述）。功能不受损，但该 enrichment 对新卡是死代码。

> 已处理：post_comment 已改为从 `card.fact` 取原文、`cardData.timestamp` 取 entry time，并移除了 `extractFactContentFromFile` / `assetAnalyses` / `agent_utils` 依赖。此条保留备查。

### 9. fact_id 懒生成可能残留 processing 占位卡
`FileSystemService.allocateCardFactId`（`save_timeline_card` 新建卡时调用）会先写一张 `processing` 占位卡来预留 `ts_N` slot（防并发撞 id），随后由 `updateCardFile` 覆盖成 completed 卡。

边角情况：若分配成功、但紧接着的 `updateCardFile` 失败（校验已在分配前完成，正常路径不会触发），会在 `Cards/` 留下一张孤儿 `processing` 占位卡（UI 显示为"处理中"且永不完成）。

> 待办：可加一个清理逻辑（如启动时回收超期未完成的 processing 占位卡），或让 `save_timeline_card` 在 updateCardFile 失败时回滚删除刚分配的占位卡。当前未处理，因正常路径不触发。

### 10. chat 图片 EXIF/地理编码逻辑与旧管道重复
`chat_service._buildImageExifInfo`（SuperAgent 图片预处理新增）复刻了 `analyze_assets_handler.dart`（约 312–407 行）的 EXIF 提取 + GPS 反向地理编码 + `getNearestUserLocation` 比对逻辑。

两处当前并存：旧 analyze_assets 已无触发入口（第 6 项），但代码仍在。待旧管道整体退役、或抽公共工具时，应合并这段重复（与第 3 项同类的重复问题）。

### 11. dart_agent_core 改为本地 path override（发版前需正式发布）
Phase 2 给 `dart_agent_core` 新增了三个 harness hook（turn-completion / pre-tool / post-tool），改的是本地源码 `/Users/ming/Downloads/project/opensource/memex-second/dart_agent_core`，并在 `memex/pubspec.yaml` 用 `dependency_overrides` 指向本地路径。

待办：正式发版前，需把带 hook 的 dart_agent_core 发布为新 pub 版本（如 1.1.0），并把 memex 的依赖从 path override 改回正式版本号。当前 path override 仅适用于本地开发。

## 确认不改（已与需求方对齐的决策）

- timeline_diagnostics 展示文案 "Associated media files:" 保留（是展示文字，不是字段名）。
- 聊天入口的音频附件：`card.assets` 与 `saveAssetFromFile` 已支持 `[audio](fs://…)`，但 `chat_service` 目前只预处理图片——仅在聊天捕获需要语音时再加音频分支。
- fact/assets 与迁移相关改动的测试已暂缓（「暂不考虑测试」），待重构稳定后补。
