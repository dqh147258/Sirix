# 2026-04-22 共享 Terminal resize 稳定性修复（阶段性搁置版）

## 背景

本轮主要处理 Sirix shared terminal 在 Desktop App / Mobile App / system terminal 共享场景下，因 resize、viewer 重连与 snapshot 放大导致的历史塌缩、重复刷新与连接抖动问题。

本次不是彻底重写 terminal server，而是在现有链路上优先保证：
- server canonical history 不再被 truncated replay 直接污染
- stale viewer resize 被吸收
- 重复 publish / 重复 snapshot apply 被收敛
- 基本可用性、稳定性和低延迟优先

## 主要改动

### 1. desktop-server canonical history-first resize

相关文件：
- `desktop-server/src/app/terminal/vt_authority.rs`
- `desktop-server/src/app/terminal/state_cache.rs`
- `desktop-server/src/app/terminal/manager.rs`

实现方式：
- 为 resize 新增 `ResizeReplayMetadata`，不再只传 replay bytes。
- 当 replay 未截断时，仍允许通过 replay 重建 parser。
- 当 replay 已截断时，改为使用 canonical `main_lines` 重建 transcript，再重建持久 parser。
- alt buffer resize 不再错误推进 main history generation。

### 2. viewer presence epoch 吸收 stale resize

相关文件：
- `desktop-server/src/api/ws.rs`
- `desktop-server/src/app/terminal/manager.rs`
- `desktop-server/src/app/tasks.rs`
- `desktop-server/src/bin/sirix.rs`
- `client/packages/feature_terminal/lib/src/terminal_view_model.dart`
- `client/packages/feature_terminal/lib/src/terminal_view_model_runtime.dart`
- `client/packages/feature_terminal/lib/src/terminal_view_model_runtime_snapshot.dart`
- `client/packages/infra_api/lib/src/desktop_local_client.dart`

实现方式：
- socket-local `terminal.ready` / `bootstrap_v2` 回包增加 `viewer_presence_epoch`。
- `terminal.resize` 请求带回 `viewer_presence_epoch`。
- server 仅接受与当前 viewer lease 匹配的 resize。
- `sirix` 系统终端 attach 后会缓存该 epoch，并随之后 resize 回传。

### 3. 重复事件 / snapshot apply 收敛

相关文件：
- `desktop-server/src/app/terminal/manager.rs`
- `client/packages/feature_terminal/lib/src/terminal_view_model.dart`
- `client/packages/feature_terminal/lib/src/terminal_view_model_runtime.dart`
- `client/packages/feature_terminal/lib/src/terminal_view_model_runtime_snapshot.dart`

实现方式：
- server 侧新增 `ResizePublishFingerprint`，跳过重复 resize publish bundle。
- Flutter 侧增加 duplicate screen snapshot、pending visible snapshot、flushed visible snapshot、history invalidated 的去重。
- Flutter 侧保留 authority cols，同时用 viewer rows 控制本地 viewport，尽量降低空白闪烁与重复 refresh。

### 4. Terminal 页面与 xterm 渲染层稳定性补强

相关文件：
- `client/packages/feature_terminal/lib/src/terminal_page.dart`
- `client/third_party/xterm/lib/src/terminal_view.dart`
- `client/third_party/xterm/lib/src/ui/render.dart`

实现方式：
- `terminal_page.dart` 新增 `_maybeReportViewportGeometry()`，在 `LayoutBuilder` 内按当前字体实际 cell 尺寸计算 cols/rows，并通过 `queueResize()` 回传 viewer 视口几何，减少移动端/窄窗口下的错配。
- `terminal_page.dart` 为每个 terminal 单独维护 `ScrollController`，通过 `_terminalScrollControllerFor()` 把垂直滚动位置持续回传给 `TerminalViewModel.onTerminalVerticalScroll()`，便于 authority cache 与当前视口联动。
- `terminal_page.dart` 通过 `_disposeInactiveTerminalControllers()` 的 post-frame 延迟释放，避免 render object 仍在 attach 时读到已 dispose 的 controller。
- `terminal_page.dart` 把 `TerminalView` 包进 `SingleChildScrollView + SizedBox + RepaintBoundary`，让 authority cols 决定真实内容宽度，减少父布局变化时对终端栅格的连带重绘。
- `terminal_view.dart` 新增 `_TerminalViewportScrollBehavior`，关闭 overscroll glow/stretch，避免软键盘 resize 与 scroll extent 修正期间触发额外 build。
- `render.dart` 调整 `RenderTerminal._onTerminalChange()`：仅当 buffer line 数变化时 `markNeedsLayout()`，否则只 `markNeedsPaint()`，降低高频输出时的不必要 layout 抖动。

### 5. 极窄窗口下 vt100 双宽字符崩溃修复

相关文件：
- `desktop-server/Cargo.toml`
- `desktop-server/Cargo.lock`
- `desktop-server/src/app/terminal/state_cache.rs`
- `third_party/vt100/src/screen.rs`
- `third_party/vt100/src/grid.rs`
- `third_party/vt100/src/row.rs`

实现方式：
- 将 `vt100 0.16.2` vendoring 到 `third_party/vt100/`，并通过 `[patch.crates-io]` 让 `desktop-server` 使用本地修复版。
- 在 `screen.rs` 的 `Screen::text()` 中补上 `width > cols` 的极端边界处理，避免双宽字符在 `1` 列终端内触发 `size.cols - width` 下溢。
- 在 `screen.rs` 与 `grid.rs` 的 wrap 判断中统一改用 `saturating_sub(width)`，去掉极窄宽度下的整数下溢路径。
- 在 `row.rs` 的 `Row::clear_wide()` 中改为边界安全的 partner 查找，遇到 resize/reflow 后残留的 orphan wide lead 时直接就地清理，不再越界 panic。
- 在 `row.rs` 的 `Row::resize()` 中补上缩窄后最后一列 wide lead 清理，提前修复被截断后的坏状态。
- 在 `state_cache.rs` 中新增接近真实日志的 narrow-width jitter 回归测试，覆盖 `51 -> ... -> 1` 列与双宽字符混排场景。

### 6. Desktop terminal viewer 与本地 channel 生命周期收敛

相关文件：
- `client/packages/feature_terminal/lib/src/terminal_page.dart`
- `client/packages/feature_terminal/lib/src/terminal_view_model.dart`
- `client/packages/feature_terminal/lib/src/terminal_view_model_events_a.dart`
- `client/packages/feature_terminal/lib/src/terminal_view_model_events_b.dart`
- `client/packages/feature_terminal/lib/src/terminal_view_model_load.dart`
- `client/packages/feature_terminal/lib/src/terminal_view_model_models.dart`
- `client/packages/feature_terminal/lib/src/terminal_view_model_runtime.dart`
- `client/packages/feature_terminal/lib/src/terminal_view_model_runtime_snapshot.dart`
- `client/packages/feature_terminal/lib/src/terminal_view_model_state_base.dart`
- `client/packages/feature_terminal/lib/src/terminal_view_model_transport_history.dart`
- `client/packages/feature_terminal/test/terminal_stream_state_test.dart`
- `desktop-server/src/api/ws.rs`
- `desktop-server/src/bin/sirix-terminal.rs`
- `desktop-server/src/cli_support.rs`

实现方式：
- `TerminalPageConfig` 的 provider identity 改成只在本地 desktop workspace（`sessionId == null`）忽略 bootstrap 阶段的 `deviceId` 变化，避免 `null -> real deviceId` 期间创建第二个 `TerminalViewModel`；remote session 仍保留 `deviceId` 作为 identity，避免切换远端设备后错误复用旧 VM。
- `terminal_page.dart` 在 `authoritySource == system_terminal` 时不再把本地 panel 几何回写给 PTY，而是通过底部横向滚动条查看超宽内容，避免 Desktop App 再次与 `sirix-terminal` 争抢几何权威。
- `TerminalAuthorityCache` 新增 `screenData` / `buildReplayBytes()`，优先用服务端下发的 formatted `screen_data_base64` 重建可见屏幕，保留彩色内容；同时在 `screen_data_base64 == ""` 时显式清空旧缓存，避免 authority rebuild 误重放陈旧屏幕。
- desktop-local terminal 列表查询改为复用 `TerminalViewModel` 自己的共享 local websocket channel，通过 `_requestDesktopLocalTerminalList()` 合并 list/attach/bootstrap 路径，减少临时 ws 重连和 duplicate attach。
- `_connectDesktopLocalChannel()` 增加 in-flight connect coalescing，并在 channel `error/done` 时回填 pending terminal-list completer，避免关闭期 list 请求悬挂。
- `_retryDesktopLocalAttachUntilReady()` 显式携带 `clientKind: desktop_app`，避免未来默认值调整后 attach 重试语义漂移。
- `sirix-terminal` 的 terminal size watcher 调整为 Unix 平台 `SIGWINCH + polling` 并行，使用去重逻辑避免重复上报；解决“前几次拖动有效，后来突然完全失效”的窗口尺寸监听问题。
- 清理大批排障期高频 trace，只保留 authority divergence、channel error/done、truncated snapshot skip 等低频边界日志，避免 runtime logs 被调试噪音淹没。

## 已完成验证

### Rust
- `cargo check --manifest-path desktop-server/Cargo.toml`
- `cargo test --manifest-path desktop-server/Cargo.toml app::terminal::state_cache::tests::resize_with_truncated_replay_rebuilds_from_canonical_history -- --exact`
- `cargo test --manifest-path desktop-server/Cargo.toml app::terminal::vt_authority::tests::resize_main_from_canonical_lines_preserves_scrollback_history -- --exact`
- `cargo test --manifest-path desktop-server/Cargo.toml app::terminal::state_cache::tests::alt_resize_does_not_advance_main_history_generation -- --exact`
- `cargo test --manifest-path desktop-server/Cargo.toml app::terminal::manager::tests::bootstrap_v2_includes_socket_local_viewer_presence_epoch -- --exact`
- `cargo test --manifest-path desktop-server/Cargo.toml app::terminal::manager::tests::stale_viewer_resize_epoch_is_ignored -- --exact`
- `cargo test --manifest-path desktop-server/Cargo.toml app::terminal::manager::tests::resize_publish_fingerprint_changes_when_resize_bundle_changes -- --exact`
- `cargo test --manifest-path third_party/vt100/Cargo.toml --lib`
- `cargo test --manifest-path desktop-server/Cargo.toml replay_resize_with_wide_chars_does_not_crash_on_narrow_width_jitter -- --nocapture`
- `flutter analyze client/packages/feature_terminal/lib/src/terminal_page.dart client/packages/feature_terminal/lib/src/terminal_view_model.dart client/packages/feature_terminal/lib/src/terminal_view_model_events_a.dart client/packages/feature_terminal/lib/src/terminal_view_model_events_b.dart client/packages/feature_terminal/lib/src/terminal_view_model_load.dart client/packages/feature_terminal/lib/src/terminal_view_model_models.dart client/packages/feature_terminal/lib/src/terminal_view_model_runtime.dart client/packages/feature_terminal/lib/src/terminal_view_model_runtime_snapshot.dart client/packages/feature_terminal/lib/src/terminal_view_model_state_base.dart client/packages/feature_terminal/lib/src/terminal_view_model_transport_history.dart client/packages/feature_terminal/test/terminal_stream_state_test.dart`
- `flutter test client/packages/feature_terminal/test/terminal_stream_state_test.dart`

### Flutter
- `flutter analyze client/packages/feature_terminal/lib/src/terminal_view_model.dart client/packages/infra_api/lib/src/desktop_local_client.dart`
- `flutter analyze client/packages/feature_terminal/lib/src/terminal_page.dart client/third_party/xterm/lib/src/terminal_view.dart client/third_party/xterm/lib/src/ui/render.dart`
- `flutter test client/packages/feature_terminal/test/terminal_stream_state_test.dart`

## 当前明确搁置的遗留问题

### 遗留问题 1：拖动宽度时历史仍可能丢失或混乱

现状：
- 比之前稳定很多，但在持续拖动列宽、特别是快速拖动时，历史重建仍然可能有部分错位、丢失或混乱。

原因摘要：
- 当前 `main + truncated` 只能用 canonical text transcript 近似重建 parser；
- 无法完整保留真实终端 parser 的样式、换行、cursor 与 TUI 上下文；
- 因此只能先守住“不要被 replay 截断压缩成一屏”，还做不到“完全无损 reflow”。

代码内已加注释位置：
- `desktop-server/src/app/terminal/vt_authority.rs`
- `desktop-server/src/app/terminal/state_cache.rs`
- `client/packages/feature_terminal/lib/src/terminal_view_model_runtime_snapshot.dart`

### 遗留问题 2：Desktop App 的当前命令行定位仍可能错误

现状：
- Desktop App 中当前应该显示的命令行/当前行位置，仍可能出现偏移或定位错误。

原因摘要：
- 当前 authority rows、viewer rows、screen snapshot apply 是折中方案；
- 为了先保证多端共享稳定性，暂未继续推进更高风险的 cursor/viewport 语义重构。

代码内已加注释位置：
- `client/packages/feature_terminal/lib/src/terminal_view_model_runtime.dart`
- `client/packages/feature_terminal/lib/src/terminal_view_model_runtime_snapshot.dart`

## 结论

除上面两个已明确接受并暂时搁置的问题外，本轮 shared terminal resize 稳定性修复在当前代码范围内未发现新的阻塞性问题，可先作为阶段性提交保留。
