# Desktop Dashboard / Branding / Terminal Polish

## 功能说明

本次改动对桌面端首页、终端工作区、品牌图标和本地 terminal 可用性做了一轮收口，目标是让 Sirix Desktop 的主工作流更聚焦于 Dashboard 内的 terminal workspace，同时补齐桌面终端在多 tab、布局切换、创建失败兜底和本地延迟展示下的可用性细节。

## 代码位置

- `client/apps/desktop_app/lib/main.dart`
- `client/apps/mobile_app/lib/main.dart`
- `client/packages/feature_auth/lib/src/auth_page_forms.dart`
- `client/packages/feature_auth/lib/src/auth_page_panels.dart`
- `client/packages/app_core/lib/src/branding/sirix_brand_mark.dart`
- `client/packages/app_core/lib/src/l10n/app_localizations.dart`
- `client/packages/app_core/lib/app_core.dart`
- `client/packages/feature_terminal/lib/src/terminal_page.dart`
- `client/packages/feature_terminal/lib/src/terminal_view_model.dart`
- `client/packages/feature_desktop_authorize/lib/src/desktop_authorize_state.dart`
- `client/packages/feature_desktop_authorize/lib/src/desktop_authorize_view_model.dart`
- `client/packages/infra_api/lib/src/desktop_local_client.dart`
- `client/packages/infra_webrtc/lib/src/desktop_media_controller.dart`
- `desktop-server/src/api/ws.rs`
- `desktop-server/src/app/terminal/manager.rs`
- `client/assets/branding/sirix_app_icon_1024.png`
- `client/android/app/src/main/AndroidManifest.xml`
- `client/android/app/src/main/res/mipmap-*/ic_launcher.png`
- `client/ios/Runner/Info.plist`
- `client/ios/Runner/Assets.xcassets/AppIcon.appiconset/*`
- `client/macos/Runner/Configs/AppInfo.xcconfig`
- `client/macos/Runner/Assets.xcassets/AppIcon.appiconset/*`
- `client/linux/CMakeLists.txt`
- `client/linux/runner/my_application.cc`
- `client/linux/runner/resources/app_icon.png`
- `client/windows/runner/main.cpp`
- `client/windows/runner/Runner.rc`
- `client/windows/runner/resources/app_icon.ico`
- `client/web/favicon.png`
- `client/web/icons/*`

## 实现方法

1. **Sirix 品牌统一与图标重建**：
   - 将桌面端、移动端、登录页与平台应用名统一为 `Sirix`，移除 `Sirix Desktop`、`Sirix Mobile`、`Sirix Console`、`Sirix Pro` 等旧命名残留。
   - 新增共享品牌组件 `SirixBrandMark`，在桌面侧边栏、登录页等活跃品牌位统一复用。
   - 生成新的主图源 `client/assets/branding/sirix_app_icon_1024.png`，并同步刷新 Android / iOS / macOS / Linux / Windows / Web 的 app icon 资源。
2. **Dashboard 页面重构**：
   - 移除旧的伪显示器卡片、`PRIMARY DISPLAY / MONITOR 02 / MONITOR 03` 等无效展示。
   - 首页顶部改为紧凑状态摘要，仅展示连接状态、登录状态、渲染帧率、延迟和“当前连接屏幕”文字说明。
   - 终端区域下沉到摘要区下方，并提供全屏切换；全屏时隐藏上方摘要区。
3. **布局层级对齐 Stitch 设计**：
   - 左侧菜单栏提升为更外层 shell chrome，Sirix 图标与标题固定在左上角。
   - 顶部 header 只承载当前 section 子标题，不再重复展示品牌块。
   - 侧边栏折叠时只保留品牌图标，展开时显示图标 + `Sirix`。
4. **终端工具栏与 tab 行为整理**：
   - `TerminalPage` 新增 `trailingTabActions`，把 fullscreen 并入 tab 右侧工具栏，与 add-tab 同组展示。
   - tab 容器改为 `Wrap + SingleChildScrollView`，tab 过多时自动换行，并保留每个 tab 的关闭按钮。
   - Dashboard 内嵌 terminal 使用 `showHeader: false / compact: true / fullBleed: true`，去掉多余标题，保持紧凑工作区形态。
5. **终端页显式复制能力**：
   - 在 `TerminalPage` 底部状态栏加入 `COPY / COPY SELECTION` 操作，让桌面用户在共享终端页中可以直接复制当前选区，而不必完全依赖快捷键记忆。
6. **终端选区与 tab 隔离**：
   - 为每个 terminal tab 分配独立 `TerminalController`，并在 tab 被关闭后及时释放对应 controller，防止旧 tab 的选区状态泄漏到新 tab，导致复制内容和 footer 状态错乱。
7. **终端空态与拖拽空间自适应**：
   - Dashboard 分栏折叠、窗口快速缩放或终端工作区临时收起时，空态容器改为先占满实际 viewport，再由内部根据高度阈值切换为 dense / ultra-compact 布局。
   - 在高度非常小的情况下会收紧 padding、缩小图标字号，并限制文案行数；若仍然放不下，则由 `SingleChildScrollView` 兜底，避免空态文案在桌面端短视口里直接 overflow。
   - Dashboard 顶部摘要区高度改为按真实卡片几何计算最小值，并限制 terminal / summary 的拖拽范围，避免首屏或拖拽后出现布局冲突。
8. **本地 terminal 输入/创建稳定性修正**：
   - `TerminalPage` 增加 terminal 激活后的显式 focus 同步与点击聚焦，避免嵌入 Dashboard 后偶发拿不到键盘焦点。
   - `TerminalViewModel` 为 desktop-local attach 增加重试，并在重试结束后用 desktop-server 的真实 terminal 列表做 reconcile；若 optimistic `OPENING` terminal 实际不存在，则移除 stale tab 并展示明确错误提示。
   - `desktop-server` 本地 shell terminal 不再因为可选的 `sirix-runtime` 缺失而直接创建失败；AI runtime 相关链路仍保留硬依赖。
9. **本地延迟探测补齐**：
   - `DesktopAuthorizeViewModel` 新增本地 ping/pong RTT 采样，把 dashboard 延迟值接入真实本地 ws 往返时间。
   - ping / pong 增加 request id 回传匹配，避免旧响应晚到后污染新一轮 latency 结果。
10. **文案与平台显示名本地化收口**：
   - 为 runtime status、全局设置、工作区设置、support / logs、terminal fullscreen tooltip、账户页标签等补齐本地化键。
   - 删除未使用的旧 dashboard 文案残留，避免后续继续引用过时术语。
