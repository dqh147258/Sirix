# 2026-04-22 Terminal 协议补齐与远程连接提速（WIP）

## 背景

本轮同时推进两条链路：

1. **shared terminal v2 协议补齐**
   - 让 App / Desktop / backend 之间真正支持 `terminal.attach`、`terminal.bootstrap.request`、`terminal.history.range.request` 这几条消息的 relay 与回源。
2. **remote connect 首连时延优化**
   - 缩短“点击连接 -> mobile offer 发出 -> desktop answer 返回”的关键路径，减少 snapshot 预热、ICE candidate 风暴和数据库热路径写入对建连的干扰。

---

## 1. backend terminal relay 补齐

### 相关文件

- `backend-server/src/api/mod.rs`
- `backend-server/src/api/terminals.rs`
- `client/packages/feature_desktop_authorize/lib/src/desktop_terminal_channel_bridge.dart`

### 做了什么

- backend 新增 `POST /api/v1/desktop/terminals/:terminal_id/events`，供 desktop 端把 terminal 事件重新注入 backend terminal event bus。
- `terminal_events_ws` 不再在 socket 建连时无条件先发一份 `terminal.ready`，而是改成由客户端显式发 `terminal.attach` 后再决定是否回 `terminal.ready`。
- backend ws inbound 新增三类消息解析：
  - `terminal.attach`
  - `terminal.bootstrap.request`
  - `terminal.history.range.request`
- `terminal.bootstrap.request` / `terminal.history.range.request` 现在会被 backend relay 到对应 desktop device 的本地事件流。
- `TerminalOutputRequest` 增加 `stream_sequence`，为后续按序消费 terminal output 留出协议字段。
- `update_terminal_state()` 中 `active` 不再映射成 `terminal.ready`，改为 `terminal.updated`，避免把“状态变成 active”误当成一次 attach/bootstrap ready。
- Flutter desktop terminal bridge 允许 `terminal.bootstrap.request` 与 `terminal.history.range.request` 透传到 desktop 本地通道，不再被误丢弃。

### 关键方法 / 入口

- `backend-server/src/api/terminals.rs`
  - `ingest_terminal_event()`
  - `resolve_attach_protocol()`
  - `resolve_bootstrap_terminal_id()`
  - `resolve_history_request()`
  - `serve_terminal_socket()`
- `client/packages/feature_desktop_authorize/lib/src/desktop_terminal_channel_bridge.dart`
  - `_isTerminalMessageType()` 对 bootstrap/history range 请求放行

---

## 2. remote connect 关键路径提速

### 相关文件

- `client/packages/feature_device_list/lib/src/device_list_view_model.dart`
- `client/packages/feature_remote_view/lib/src/remote_view_view_model.dart`
- `client/packages/feature_desktop_authorize/lib/src/desktop_authorize_view_model.dart`
- `client/packages/infra_webrtc/lib/src/remote_stream_controller.dart`
- `client/packages/infra_webrtc/lib/src/desktop_media_controller.dart`
- `backend-server/src/api/webrtc.rs`

### 做了什么

- mobile 端 `attachSession()` 调整为：
  - 先绑定媒体流与 event stream
  - 非 `pending_approval` 场景先发 initial offer
  - snapshot 列表改为后台 warmup，不再阻塞首个 offer
- 新增 `[REMOTE_CONNECT_TRACE]` 日志，覆盖：
  - create connection request 开始/结束/失败
  - attach session 开始
  - mobile stream ready
  - initial offer start/sent/failed
  - connection accepted
  - remote answer applied
  - session streaming
  - desktop offer received / answer ready
- mobile 和 desktop 的 WebRTC controller 都改成：
  - **先缓存本地 ICE candidate**
  - 等 offer / answer 主 SDP 成功发出后再串行释放 candidate
  - 避免 candidate 风暴抢占 HTTP / backend / desktop 事件链
- desktop 本地 websocket 连上后，后台调用 `warmUpRtc()` 预热一次 `createPeerConnection() -> close()`，把 flutter_webrtc 的冷启动成本前置到空闲阶段。
- backend `relay_signal()` 不再为每个 ICE candidate 都写 `session_events`，只保留 offer / answer 的持久化审计，减少高频数据库写入。

### 关键方法 / 入口

- `client/packages/feature_remote_view/lib/src/remote_view_view_model.dart`
  - `attachSession()`
  - `_sendInitialOffer()`
  - `_warmUpRemoteWorkspace()`
  - `_startConnectTrace()`
  - `_logConnectTrace()`
- `client/packages/infra_webrtc/lib/src/remote_stream_controller.dart`
  - `_beginBufferingLocalIceCandidates()`
  - `_enqueueOrDispatchLocalIceCandidate()`
  - `releaseBufferedLocalIceCandidates()`
- `client/packages/infra_webrtc/lib/src/desktop_media_controller.dart`
  - `warmUpRtc()`
  - `_performRtcWarmUp()`
  - `_releaseBufferedLocalIceCandidates()`
- `backend-server/src/api/webrtc.rs`
  - `should_persist_signal_event()`

---

## 3. hosted shell 断连退化处理

### 相关文件

- `desktop-server/src/bin/sirix-terminal.rs`

### 做了什么

- 当 hosted shell 与 desktop-server 的 websocket 因 server 被强杀、peer reset、broken pipe 等原因断开时，不再直接把这类常见断链都当成 fatal error。
- 现在会通过 `is_graceful_host_disconnect()` 识别这类“宿主端已断开”的错误，输出提示后安全 break，让 shared shell 更平滑退场。

### 关键方法

- `is_graceful_host_disconnect()`
- `run_hosted_terminal()`

---

## 已完成验证

### Rust

- `cargo check --manifest-path backend-server/Cargo.toml`
- `cargo test --manifest-path backend-server/Cargo.toml --no-run`
- `cargo check --manifest-path desktop-server/Cargo.toml`
- `cargo test --manifest-path desktop-server/Cargo.toml --no-run`
- `cargo test --manifest-path third_party/codex-rs/Cargo.toml -p codex-core -p codex-tools -p codex-tui --no-run`

### Flutter

- `flutter analyze packages/feature_desktop_authorize/lib/src/desktop_authorize_view_model.dart packages/feature_desktop_authorize/lib/src/desktop_terminal_channel_bridge.dart packages/feature_device_list/lib/src/device_list_view_model.dart packages/feature_remote_view/lib/src/remote_view_view_model.dart packages/feature_terminal/lib/src/terminal_page.dart packages/infra_webrtc/lib/src/desktop_media_controller.dart packages/infra_webrtc/lib/src/remote_stream_controller.dart third_party/xterm/lib/src/terminal_view.dart third_party/xterm/lib/src/ui/render.dart`
- `flutter test packages/feature_terminal/test/terminal_stream_state_test.dart`

---

## 当前状态

- terminal v2 relay / bootstrap / history range 的链路已在 backend 与 Flutter desktop bridge 上补齐基础通路。
- remote connect 首连路径里的几个主要阻塞点（snapshot 阻塞、desktop RTC 冷启动、ICE candidate 抢占、candidate 逐条落库）已经先做了一轮收敛。
- 目前仍属于 **WIP 状态**，后续若继续推进，需要再结合真实设备日志验证：
  - auto approve / manual approve 的真实首连耗时差异
  - desktop 侧 answer 后 candidate 排空是否存在边界时序问题
  - terminal history range 请求在真实 shared terminal 长历史场景下是否稳定
