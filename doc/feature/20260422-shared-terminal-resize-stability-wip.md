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

## 已完成验证

### Rust
- `cargo check --manifest-path desktop-server/Cargo.toml`
- `cargo test --manifest-path desktop-server/Cargo.toml app::terminal::state_cache::tests::resize_with_truncated_replay_rebuilds_from_canonical_history -- --exact`
- `cargo test --manifest-path desktop-server/Cargo.toml app::terminal::vt_authority::tests::resize_main_from_canonical_lines_preserves_scrollback_history -- --exact`
- `cargo test --manifest-path desktop-server/Cargo.toml app::terminal::state_cache::tests::alt_resize_does_not_advance_main_history_generation -- --exact`
- `cargo test --manifest-path desktop-server/Cargo.toml app::terminal::manager::tests::bootstrap_v2_includes_socket_local_viewer_presence_epoch -- --exact`
- `cargo test --manifest-path desktop-server/Cargo.toml app::terminal::manager::tests::stale_viewer_resize_epoch_is_ignored -- --exact`
- `cargo test --manifest-path desktop-server/Cargo.toml app::terminal::manager::tests::resize_publish_fingerprint_changes_when_resize_bundle_changes -- --exact`

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

### 遗留问题 2：Desktop App 的当前命令行定位仍可能错误

现状：
- Desktop App 中当前应该显示的命令行/当前行位置，仍可能出现偏移或定位错误。

原因摘要：
- 当前 authority rows、viewer rows、screen snapshot apply 是折中方案；
- 为了先保证多端共享稳定性，暂未继续推进更高风险的 cursor/viewport 语义重构。

代码内已加注释位置：
- `client/packages/feature_terminal/lib/src/terminal_view_model.dart`

## 结论

除上面两个已明确接受并暂时搁置的问题外，本轮 shared terminal resize 稳定性修复在当前代码范围内未发现新的阻塞性问题，可先作为阶段性提交保留。
