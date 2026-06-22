# 动态卡片渲染自检工具及相关修复

> 本文档记录在 `codex/super-agent-entry` 分支基础上、本次会话新增的改动，与分支本身的功能分析（见 `super-agent-entry-changes.md`）分开。

涉及四块改动：

1. **渲染自检工具** `preview_dynamic_timeline_card_render`（新功能）
2. **图片投递改用 UserMessage 注入**（修复 OpenAI 兼容 provider 报错）
3. **克隆对话框 controller dispose 崩溃修复**
4. **剪贴板预览二进制内容过滤**

---

## 1. 渲染自检工具 `preview_dynamic_timeline_card_render`

### 动机

agent 用 `dynamic_timeline_ui` skill 生成 HTML 卡片后，**看不到它在 Timeline WebView 卡片里实际长什么样**，只能盲写 HTML，无法验证布局/样式。本工具让 agent 把候选 HTML 渲染成图片回传给 LLM 自检，再决定是否 create/update。

### 整体链路

```
skill 工具(html) → sanitize → 包裹成 timeline 文档 → 原生离屏渲染 → base64 PNG
                                                              ↓
                          经会话级缓冲 + systemCallback 注入 UserMessage → LLM 看图
```

1. **`preview_dynamic_timeline_card_render(html, width?)`**（`dynamic_timeline_ui_skill.dart`）：先复用既有 `sanitizeHtmlForTimeline` 做与 create/update 一致的安全校验。
2. **`HtmlWebViewCard.buildTimelineHtmlDocument(html)`** 把原始 HTML 包裹成与 live 卡片**像素一致**的完整文档。该静态函数是从 `_wrapHtmlWithScript` 抽出的共享逻辑（CSS 规范化 + 结构包裹 + `_removeBorderRadius`）——live 卡片路径额外注入高度/点击 `<script>`，截图路径不注入（脚本对像素无影响，离屏也没有 HeightChannel/ClickChannel）。
3. **`WebviewSnapshotService.renderHtmlToImage()`**（新文件 `lib/data/services/webview_snapshot_service.dart`）经既有 channel `com.memexlab.memex/webview` 调原生新方法 `renderHtmlToImage`，返回 base64 PNG 解码成 `Uint8List`。
4. **原生离屏渲染**（`WebViewChannelHandler` 的 iOS Swift / Android Kotlin 各加一个 method）：创建**独立的离屏裸 WebView**（非 PlatformView）→ loadHTML → 量 `document.body.scrollHeight` → 延迟一帧待布局稳定 → iOS `WKWebView.takeSnapshot` / Android `webView.draw(Canvas)` → base64 PNG。
5. **图片回传**：见下一节（不走 tool result）。

### 为何用原生离屏截图，而非照搬详情页分享

详情页分享（`ShareService`）用 `screenshot` 包的 `captureFromWidget`，在 **Flutter 渲染层**截图。但 `webview_flutter` 在 Android 是 hybrid composition 平台视图，Flutter 层截它常得到**空白**。

本工具在**原生 WebView 内部**截图（iOS `WKWebView.takeSnapshot` / Android `webView.draw`），绕开平台合成层，iOS/Android 都可靠。且离屏裸 WebView 由原生侧自己创建、与 Timeline 上可见的卡片 WebView 完全隔离，不存在"截到哪一个"的歧义，也不需要 Dart 端挂 Overlay。

> 备选方案 `flutter_inappwebview` 自带 `takeScreenshot()` 保真度最高，但要把全 app 的 `webview_flutter` 渲染心脏整体迁移、回归面大，为单个工具不划算，故未采用。

### 边界

- 保持 `webview_flutter` 不变，**未引入** `flutter_inappwebview` / html2canvas。
- 不改 Timeline 渲染路径。
- `width` 默认 390（=卡片宽度）、`maxHeight` 3000（=`_TimelineConfig.maxHeight`）以控制 token。
- 渲染失败/平台不支持时，工具返回纯文本提示 agent 凭 HTML 规则自查。
- systemPrompt 增补指引：**create/update 前先 preview 自检**。

---

## 2. 图片投递：改用 UserMessage 注入

### 问题

最初实现用 `AgentToolResult(contents: [TextPart, ImagePart])` 把图片放进 **tool result 消息**，在 `memex-default`（OpenAI 兼容 provider）上直接报错：

```
Unsupported tool call result content type for model memex-default: ImagePart
```

（截图渲染本身是成功的，日志 `preview_dynamic_timeline_card_render: Success`——纯粹是投递通道的问题。）

### 根因（已核实）

- **OpenAI 兼容协议的 tool/function 结果消息只允许文本**：core 的 `openai_client.dart` 序列化 `FunctionExecutionResultMessage` 时，遇到非 `TextPart` 直接抛异常。这是 OpenAI API 的硬限制，不是 bug。
- 但**三家 provider 的 UserMessage 都支持图片**：`openai_client.dart`（`ImagePart` → `image_url`）、`gemini_client.dart`、`claude_client.dart`。这也是聊天附件流能给同一 provider 发图的原因。
- 工具 executable 只能返回 `AgentToolResult`（→ tool result 消息），**无法直接追加 UserMessage**。

### 方案

图片改走 UserMessage 投递，统一适配三家 provider：

1. **`PendingToolImageBuffer`**（新文件 `lib/agent/super_agent/pending_tool_image_buffer.dart`）：单例、纯内存、按 sessionId 隔离的图片中转缓冲。`add(sessionId, ImagePart)` 入队，`drain(sessionId)` 一次性取出并清空。
2. **skill 改写**：`_previewDynamicTimelineCard` 渲染拿到 bytes 后，把 `ImagePart` 存进缓冲（sessionId 取 `AgentCallToolContext.current.state.sessionId`），tool result **只回纯文本**（告诉模型"图片作为下一条消息附上，本轮就看")。
3. **callback 注入**：`super_agent.dart` 的 `_createSuperAgentSystemCallback` 在调 LLM 前 `drain` 出图片，构造一条 `UserMessage([TextPart, ...ImageParts])` 追加到 `requestMessages` 末尾。

### 为什么不会被持久化（已逐行核实 core）

`requestMessages` 在每轮循环开头由 `List.from(state.history.messages)` 构造——是**副本**。core 中 `state.history.messages` 的全部写入点只有 4 处（episodic 注入、初始输入、模型响应、模型响应+工具结果），**没有任何一处从 `requestMessages` 回写历史**。`autoSaveStateFunc` 保存的是 `state.history`。所以注入的图片：

- ✅ 只进入紧邻的那一次 LLM 请求
- ✅ 不进 `state.history`，不被持久化、不膨胀 agent state
- ✅ 下一轮 `requestMessages` 重新拷贝，旧注入自动消失

### 一次性可见的取舍

图片只在紧接着的那次 LLM 调用可见，下一轮就没了。这是**够用**的：工具执行后必然会再调一次 LLM 解读结果，图片就搭在那次；模型对图片的判断会以**文本**形式沉淀进它的响应、被持久化。要再看就**重新调 preview**（重渲染成本很低）。

systemPrompt 已明确指引：**"渲染图只随本轮提供一次，请在本轮内看完并据此决定 create/update 或重新 preview，不要假设下一轮还能看到它。"**

> 与上下文压缩"剥离归档图片 base64"理念一致——图片是一次性观察输入，不该长期占 token。

### sessionId 一致性

skill 入缓冲用 `AgentCallToolContext.current.state.sessionId`，callback 取出用 `agent.state.sessionId`。core 中 `AgentCallToolContext` 构造时 `state: state, agent: this` 是**同一个 state 对象**，整个 run loop 共用，故两者必然相等，缓冲对得上。

---

## 3. 克隆对话框 controller dispose 崩溃修复

### 现象

打开"克隆到测试用户"对话框，点取消时抛：

```
A TextEditingController was used after being disposed.
```

### 根因

`personal_center_screen.dart` 的 `_showCloneToTestUserDialog()` 原本在 `finally { controller.dispose() }` 释放 `TextEditingController`。`await showDialog` 在 `Navigator.pop` 瞬间就 resolve，controller 立即被释放——但对话框**退场动画还在播**，`TextField` 在过渡中继续 rebuild 并 `addListener`，访问到已 dispose 的 controller 即崩溃（点取消必现）。

### 修复

把对话框内容抽成独立的 `_CloneToTestUserDialog`（StatefulWidget），controller 改在其 `State.dispose()` 里释放——该回调只在路由真正移除（动画结束后）才触发。`overwriteTarget` / `touched` 一并改为 State 字段。

---

## 4. 剪贴板预览二进制内容过滤

### 现象

复制图片后，首页"新剪贴板"预览卡片显示满屏乱码（含 `Exif`、`MM`、`*` 等图片头标记与 `�` 替换字符）。

### 根因

`clipboard_preview_service.dart`（该功能来自 main 合并进来的 `d1eddfa`）只取 `Clipboard.kTextPlain` 且不校验内容是否为可读文本。某些来源 App 复制图片时会把原始字节也塞进 `text/plain` 槽位，于是预览把二进制按字符串渲染成乱码。

### 修复

在拿到剪贴板文本后加一道 `_looksLikeBinary(text)` 检测，命中则 `return null`（不弹预览）：统计 `U+FFFD`（解码失败的替换符）、`0x7F`、`< 0x20` 的控制字符（放行 tab/换行/回车）比例，超过 5% 即判为二进制。正常文本该比例≈0，不会误伤。

---

## 改动文件清单

| 文件 | 性质 | 内容 |
|---|---|---|
| `lib/data/services/webview_snapshot_service.dart` | 新增 | Dart 侧封装 `renderHtmlToImage` channel 调用 |
| `lib/agent/super_agent/pending_tool_image_buffer.dart` | 新增 | 会话级图片中转缓冲 |
| `ios/Runner/WebViewChannelHandler.swift` | 改 | 新增 `renderHtmlToImage`（离屏 WKWebView + takeSnapshot） |
| `android/.../channels/WebViewChannelHandler.kt` | 改 | 新增 `renderHtmlToImage`（离屏 WebView + draw Canvas） |
| `lib/ui/core/widgets/html_webview_card.dart` | 改 | 抽出共享静态函数 `buildTimelineHtmlDocument` |
| `lib/agent/skills/dynamic_timeline_ui/dynamic_timeline_ui_skill.dart` | 改 | 新增 preview 工具、图片入缓冲、systemPrompt 指引 |
| `lib/agent/super_agent/super_agent.dart` | 改 | callback 注入图片 UserMessage |
| `lib/ui/settings/widgets/personal_center_screen.dart` | 改 | 克隆对话框抽成 StatefulWidget 修复 dispose |
| `lib/data/services/clipboard_preview_service.dart` | 改 | 二进制内容过滤 |

---

## 验证现状

- `flutter analyze` 全项目 **0 error**，改动文件无 error/warning。
- Android `compileGlobalEarlyDebugKotlin`、iOS `flutter build ios --no-codesign` 均编译通过。
- **待真机验证**：
  1. `memex-default`（OpenAI 兼容）上让 agent 生成卡片 → 确认不再报 `Unsupported tool call result content type`，且后续回复体现"看到了"渲染图。
  2. iOS / Android 双端截图非空白（重点 Android hybrid composition）。
  3. 连续两次 preview 不串旧图。
  4. 克隆对话框点取消不再崩溃。
  5. 复制图片时剪贴板预览不再弹乱码卡片。
