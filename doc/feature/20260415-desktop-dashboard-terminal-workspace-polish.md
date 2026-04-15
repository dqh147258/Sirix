# Desktop Dashboard Terminal Workspace Polish

## 功能说明

本次改动对桌面端首页、终端工作区和品牌文案做了一轮收口，目标是让 Sirix Desktop 的主工作流更聚焦于 Dashboard 内的 terminal workspace，同时补齐桌面终端在多 tab、复制快捷键和布局切换下的可用性细节。

## 代码位置

- `client/apps/desktop_app/lib/main.dart`
- `client/lib/src/shell/desktop_shell_page.dart`
- `client/packages/feature_auth/lib/src/auth_page_forms.dart`
- `client/packages/feature_terminal/lib/src/terminal_page.dart`
- `client/third_party/xterm/lib/src/terminal_view.dart`

## 实现方法

1. **品牌文案统一**：
   - 将桌面主应用顶部栏、桌面 shell 头部和登录页中的 `RemoteTerm` 统一替换为 `Sirix` / `Sirix Pro`，避免桌面端仍残留旧品牌名称。
2. **Dashboard 顶栏与终端工作区聚焦**：
   - 顶栏仅展示当前激活 section，不再保留没有真实内容映射的占位 tab，避免用户把无效入口误判为可点击导航。
   - Dashboard 主体拆分为显示区与终端区两个明确组件，并增加 terminal workspace 的展开 / 还原切换；切换布局时保持 `TerminalPage` 挂载，避免展开后打断现有 PTY 会话或重置 tab。
3. **终端页显式复制能力**：
   - 在 `TerminalPage` 底部状态栏加入 `COPY / COPY SELECTION` 操作，让桌面用户在共享终端页中可以直接复制当前选区，而不必完全依赖快捷键记忆。
4. **终端选区与 tab 隔离**：
   - 为每个 terminal tab 分配独立 `TerminalController`，并在 tab 被关闭后及时释放对应 controller，防止旧 tab 的选区状态泄漏到新 tab，导致复制内容和 footer 状态错乱。
5. **平台快捷键行为修正**：
   - 在 `xterm` 视图中仅对平台真实复制快捷键做“优先复制选区”处理：macOS / iOS 使用 `Cmd+C`，Windows / Linux 使用 `Ctrl+Shift+C`。
   - 保留 Windows / Linux 上普通 `Ctrl+C` 直通 shell 的行为，避免用户在已有选区时无法向 PTY 发送中断信号。
