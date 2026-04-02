# UI 与 Remote Terminal 设计方案

日期: 2026-04-02

## 1. 目标

本方案基于当前仓库已落地代码设计，目标分为两部分:

- UI 重构: 将 `desktop_app`、`mobile_app` 的登录页、主页、授权弹窗、移动端屏幕切换页重做为统一的深色玻璃拟态风格。
- Remote Terminal: 新增真实 PTY 终端能力，由桌面端发起/承载，移动端实时同步并可交互，支持 ANSI 颜色、TUI、窗口 resize、输入输出。

本阶段只输出方案，不直接改业务代码。

## 2. 当前代码现状

### 2.1 Flutter 端

当前入口与职责:

- `client/apps/desktop_app/lib/main.dart`
  - 未登录时直接显示 `AuthPage`
  - 登录后仅有 `授权` / `账号` 两个 Tab
- `client/apps/mobile_app/lib/main.dart`
  - 三个底部导航: `账号` / `设备` / `远程查看`
- `client/packages/feature_auth/lib/src/auth_page.dart`
  - 当前是非常基础的表单 + 登录/注册按钮
- `client/packages/feature_device_list/lib/src/device_list_page.dart`
  - 当前是基础设备卡片列表
- `client/packages/feature_remote_view/lib/src/remote_view_page.dart`
  - 已支持远程视频查看、切屏、码率、横竖屏切换
  - 当前移动端“主页”和“屏幕切换”都还是功能页，不是你给出的视觉稿风格
- `client/packages/feature_desktop_authorize/lib/src/desktop_authorize_page.dart`
  - 当前为列表式授权页，未做弹窗化和视觉强化
- `client/packages/app_core/lib/src/theme/app_theme.dart`
  - 目前仅 `ColorScheme.fromSeed(...)`，没有品牌色板、字体体系、玻璃面板样式封装

### 2.2 Rust 服务端

当前已具备:

- `backend-server`
  - 认证
  - 设备注册、在线状态、自动授权设置
  - 连接请求、会话状态、切屏、码率控制
  - 桌面/移动事件流
  - WebRTC 信令转发
- `desktop-server`
  - 本地 WS 与桌面 Flutter 通信
  - 与 backend 通信
  - 屏幕快照与多屏上传
  - 会话授权转发

当前缺失:

- 不存在真实 PTY/Terminal 会话模型
- 没有 terminal 输入输出协议
- 没有 terminal 的 Flutter UI 组件与共享状态

## 3. 设计原则

- 不改变当前产品角色分工:
  - 桌面端仍以“设备端控制台”身份存在
  - 移动端仍以“远程控制/远程查看”身份存在
- 风格统一，但文案和信息结构按当前产品语义重写，不直接照抄参考稿
- UI 重构优先复用现有 `feature_*` 模块，避免把所有页面逻辑重新塞回 app 入口
- Terminal 设计按真实可落地链路定义，避免只做 UI 占位
- 先保证 macOS/Linux 可落地，Windows 作为后续扩展项

## 4. 视觉系统方案

## 4.1 统一主题

建议先在 `app_core` 中建立一层品牌主题，而不是每个页面散写颜色。

建议新增:

- `AppTheme.darkSirix()`
- `ThemeExtension` 或等价品牌 token:
  - 背景色
  - surface 系列
  - neon green 主强调色
  - cyan 次强调色
  - 错误色
  - 玻璃面板边框色
  - 阴影与 glow
- 字体:
  - 标题: `Space Grotesk`
  - 正文: `Inter`
  - 等宽: `JetBrains Mono`

建议新增共用样式组件:

- `SirixGlassPanel`
- `SirixPrimaryButton`
- `SirixSecondaryButton`
- `SirixStatusChip`
- `SirixSectionCard`
- `SirixBackdrop`

## 4.2 半透明/模糊效果可行性

可行，Flutter 实现难度中低。

建议实现方式:

- 静态背景层: 渐变 + 模糊几何光斑
- 玻璃卡片: `ClipRRect + BackdropFilter + 半透明背景色 + 细边框`
- 登录页与授权弹窗优先启用 blur
- 视频预览页上的浮层只在小面积控件使用 blur，避免对远程画面叠太多大面积模糊层

降级策略:

- 若个别移动设备/平台 blur 性能差，则保留半透明底色与边框，关闭 `BackdropFilter`

结论:

- 登录页的半透明效果建议保留，不需要放弃

## 5. UI 改造方案

## 5.1 登录页

### 桌面端

目标:

- 登录框绝对居中
- 使用参考稿的深色终端控制台视觉语言
- 保留当前真实交互: 用户名、密码、登录、注册、错误提示、加载态

方案:

- `desktop_app` 未登录页改为全屏沉浸式认证页，不再使用当前顶部 AppBar
- 背景:
  - 模拟控制台 blueprint 栅格
  - 底部绿色 glow
- 中央卡片:
  - 品牌区
  - 用户名输入
  - 密码输入
  - 登录主按钮
  - 注册次按钮
  - 错误信息 / loading 状态

文案调整:

- 用中文产品语义，不直接复用示例中的英文黑客风文案
- 例如可使用:
  - 标题: `Sirix Console`
  - 副标题: `安全远程协作入口`

实现位置:

- `client/packages/feature_auth/lib/src/auth_page.dart`
- `client/apps/desktop_app/lib/main.dart`

### 移动端

目标:

- 保持同一套色彩和品牌风格
- 适配窄屏和软键盘
- 登录/注册共存

方案:

- 使用竖向居中的品牌头 + 卡片式表单
- 背景采用抽象光斑，不做复杂 dashboard blueprint
- 提高输入框高度和点击命中区域
- 表单与底部安全区域留白分离

实现位置:

- `client/packages/feature_auth/lib/src/auth_page.dart`
- `client/apps/mobile_app/lib/main.dart`

## 5.2 桌面端主页

这里明确是改当前 `desktop_app` 登录后的主界面，不新建第二个桌面产品。

### 结构建议

将当前登录后简单 `TabBar` 页面改为控制台布局:

- 顶部状态栏
  - 本地连接状态
  - 设备在线状态
  - 当前账号
  - 退出按钮
- 左侧导航
  - 控制台
  - 授权请求
  - 终端
  - 账号
- 主内容区
  - 上半区: 设备状态 / 屏幕信息 / 授权概览
  - 下半区: Terminal 区域

### 内容映射

参考稿的“主显示器 + 小窗预览 + 底部 Terminal”不建议一比一照搬成“本机预览器”，而是映射为当前真实能力:

- 主卡片:
  - `desktop-server` 连接状态
  - 当前共享屏幕 ID
  - 注册设备 ID
  - 最近事件
  - 待处理授权数量
- 右侧预览区:
  - 本机屏幕快照缩略图
  - 若本地暂时拿不到快照，则显示占位卡
- 下半区:
  - 活跃 Terminal tabs
  - 终端输出

原因:

- 当前桌面端产品定位不是“自己远控自己”的观看端
- 直接上本机实时大预览会和现有职责冲突
- 但缩略图/屏幕资产卡可用于增强仪表盘感和多屏可见性

实现建议:

- 用 `NavigationRail` 或自定义侧边栏替代当前 `DefaultTabController`
- `DesktopAuthorizePage` 重构成控制台子页面
- 新增 `DesktopDashboardPage`
- 新增 `TerminalWorkspacePage`

候选改动文件:

- `client/apps/desktop_app/lib/main.dart`
- `client/packages/feature_desktop_authorize/lib/src/desktop_authorize_page.dart`
- 新建 `client/packages/feature_terminal/...`

## 5.3 移动端主页

目标:

- 把当前 “设备列表 + 远程查看” 的功能页整合成更完整的移动控制台体验
- 视觉贴近参考稿，但仍基于现有连接逻辑

建议信息架构:

- 顶部 AppBar:
  - 品牌
  - 实时状态 chip
  - 设置/账号入口
- 主区上半部:
  - 远程画面区域
  - 状态浮层: latency / fps / bitrate / session state
- 中部:
  - Terminal tabs
  - 当前终端视图
- 底部导航:
  - 设备
  - 终端
  - 监视器
  - 账号

这里不建议继续维持当前单独的“设备页”和“远程查看页”强割裂结构。建议改为:

- 设备列表作为一个入口面板或独立 tab
- 连上设备后，主页默认进入远程工作台

实现落点:

- `client/apps/mobile_app/lib/main.dart`
- `client/packages/feature_device_list/lib/src/device_list_page.dart`
- `client/packages/feature_remote_view/lib/src/remote_view_page.dart`
- 新建 `client/packages/feature_terminal/...`

## 5.4 移动端屏幕切换

当前是设置 tab 中的屏幕列表。建议改成单独的全屏 overlay。

目标:

- 从远程画面页直接点开
- 全屏展示多屏快照
- 当前屏幕高亮，其他屏幕可一键切换

方案:

- 在 `RemoteViewState` 增加:
  - `bool monitorPickerVisible`
- 浮动按钮:
  - 常驻右下角监视器切换按钮
- Overlay 内容:
  - 顶部标题 + 关闭
  - 使用 grid 展示 `state.snapshots`
  - 当前选中屏幕显示高亮边框与 active badge

实现位置:

- `client/packages/feature_remote_view/lib/src/remote_view_state.dart`
- `client/packages/feature_remote_view/lib/src/remote_view_view_model.dart`
- `client/packages/feature_remote_view/lib/src/remote_view_page.dart`

## 5.5 桌面端授权弹窗

当前 `DesktopAuthorizePage` 是列表式卡片，不是弹窗。

目标:

- 当移动端发起连接请求时，在桌面端控制台上方弹出 modal
- 信息更聚焦，操作优先级更明确

方案:

- `pendingRequests` 非空时，在桌面控制台页面上叠加 modal
- 背景做暗化 + 轻微 blur
- modal 主体展示:
  - 请求来源设备
  - session id
  - target device
  - 时间
  - 授权 / 拒绝按钮

当前数据不足项:

- 现有 `PendingAuthorizeRequest` 只有:
  - `sessionId`
  - `requester`
  - `deviceName`
- 没有:
  - IP
  - 地理位置
  - 设备型号
  - 发起时间字符串

因此本次设计建议:

- UI 先基于现有字段展示
- 若要达到参考稿细节，需要补协议字段

协议扩展建议:

- backend `session.requested` payload 补充:
  - `requester_label`
  - `requester_client_type`
  - `requested_at`
- desktop-server 本地 WS `authorize.request` 透传同样字段

实现位置:

- `client/packages/feature_desktop_authorize/lib/src/desktop_authorize_state.dart`
- `client/packages/feature_desktop_authorize/lib/src/desktop_authorize_view_model.dart`
- `desktop-server/src/app/tasks.rs`
- `backend-server/src/api/connections.rs`

## 6. Remote Terminal 设计方案

## 6.1 需求拆解

你要求的是 A:

- 桌面端可建立真实 Terminal
- 移动端同步 Terminal 信息
- 移动端可远程访问并交互
- 桌面端和移动端都要支持颜色、ANSI、TUI

这意味着不能用“命令执行日志”或“行文本模拟”替代，必须实现真实 PTY。

## 6.2 设计结论

建议采用以下链路:

- PTY 宿主: `desktop-server`
- terminal 数据平面: WebSocket 双向流
- 客户端渲染: Flutter `xterm.dart` 类终端组件
- 控制与发现: `backend-server`

不建议:

- 复用现有移动事件流承载终端字节流
- 用 HTTP 轮询传输输入输出
- 用普通 `Text`/`SelectableText` 模拟终端

## 6.3 组件分工

### desktop-server

新增职责:

- 创建/维护 PTY 会话
- 启动 shell 进程
- 读 stdout/stderr
- 写 stdin
- 处理 resize
- 处理 close
- 将 terminal 元数据同步给 backend
- 通过专用 WS 与 backend 交换 terminal 帧

建议新增模块:

- `desktop-server/src/terminal/mod.rs`
- `desktop-server/src/terminal/manager.rs`
- `desktop-server/src/terminal/session.rs`
- `desktop-server/src/terminal/protocol.rs`

建议依赖:

- `portable-pty`
  - 优点: macOS/Linux/Windows 兼容性相对好
  - 适合真实 shell + ANSI + TUI

### backend-server

新增职责:

- terminal session 元数据管理
- 鉴权
- terminal relay
- 会话参与者管理
- 终端创建/关闭/同步事件广播

建议新增模块:

- `backend-server/src/api/terminals.rs`
- `backend-server/src/api/terminal_events.rs` 或 session-specific ws
- `backend-server/src/application/terminal_hub.rs`

### Flutter client

新增共享 feature 包:

- `client/packages/feature_terminal/`

职责:

- 终端列表
- 终端 tab 管理
- `xterm` 渲染
- 输入桥接
- resize
- 会话状态展示

## 6.4 Terminal 数据模型

建议新增后端实体:

- `terminal_sessions`
  - `id`
  - `device_id`
  - `creator_user_id`
  - `title`
  - `shell`
  - `cwd`
  - `state` (`opening|active|closed|error`)
  - `cols`
  - `rows`
  - `created_at`
  - `updated_at`
  - `closed_at`
- `terminal_session_participants`
  - `session_id`
  - `user_id`
  - `client_type`
  - `joined_at`

说明:

- 不建议持久化完整 terminal 输出内容
- 会话事件可保留在 `session_events` 或新增 terminal 事件流水

## 6.5 协议设计

### 6.5.1 Flutter <-> backend

新增 HTTP:

- `POST /api/v1/terminals`
  - 创建 terminal session
  - 入参:
    - `target_device_id`
    - `cols`
    - `rows`
    - `cwd` 可选
    - `shell` 可选
- `GET /api/v1/terminals`
  - 查询当前用户可见 terminal 会话
- `POST /api/v1/terminals/{terminal_id}/close`

新增 WS:

- `GET /api/v1/terminals/{terminal_id}/ws`

消息类型建议:

- client -> backend
  - `terminal.input`
  - `terminal.resize`
  - `terminal.ping`
  - `terminal.close`
- backend -> client
  - `terminal.ready`
  - `terminal.output`
  - `terminal.resized`
  - `terminal.closed`
  - `terminal.error`

`terminal.output` 建议承载原始字节流的 base64。

原因:

- ANSI/TUI 需要保留控制字符
- 直接 JSON 字符串不可靠

### 6.5.2 backend <-> desktop-server

建议新增专用 terminal relay WS，而不是继续塞进现有 desktop event 流。

新增:

- `desktop-server` 启动后建立 `terminal relay websocket`
- backend 根据 `device_id` 路由 terminal 帧到目标 desktop-server

消息类型建议:

- backend -> desktop
  - `terminal.create`
  - `terminal.input`
  - `terminal.resize`
  - `terminal.close`
- desktop -> backend
  - `terminal.created`
  - `terminal.output`
  - `terminal.closed`
  - `terminal.error`

## 6.6 桌面端创建 Terminal 的业务流程

建议流程:

1. 用户在桌面 Flutter 点击“新建 Terminal”
2. 桌面 Flutter 通过本地 WS 请求 `desktop-server` 创建 PTY
3. `desktop-server` 创建成功后:
   - 本地立即返回 terminal session metadata 给桌面 Flutter
   - 同步向 backend 注册 terminal session
4. backend 向移动端事件流发布:
   - `terminal.session.created`
5. 移动端可在 terminal 列表中看到新会话
6. 移动端进入 terminal 后，通过 backend terminal ws attach
7. backend 与 desktop-server relay 输出和输入

这样设计的原因:

- “桌面端可以建立 Terminal” 的入口必须在桌面端本机
- 桌面端和移动端看到的是同一个 session id

## 6.7 桌面 Flutter 与 desktop-server 的本地协议扩展

当前本地 WS 只有:

- `settings.set_auto_approve`
- `authorize.response`
- `webrtc.signal`

建议扩展:

- Flutter Desktop -> desktop-server
  - `terminal.create`
  - `terminal.input`
  - `terminal.resize`
  - `terminal.close`
  - `terminal.list`
- desktop-server -> Flutter Desktop
  - `terminal.created`
  - `terminal.output`
  - `terminal.closed`
  - `terminal.error`
  - `terminal.list`

实现文件:

- `client/packages/infra_api/lib/src/desktop_local_client.dart`
- `desktop-server/src/api/ws.rs`

## 6.8 Flutter Terminal UI 方案

建议新增共享 package:

- `client/packages/feature_terminal/`

建议依赖:

- `xterm`

内部结构建议:

- `terminal_page.dart`
- `terminal_workspace.dart`
- `terminal_view_model.dart`
- `terminal_state.dart`
- `terminal_models.dart`
- `terminal_ws_client.dart`

桌面端:

- 支持 tabbed terminals
- 支持新建/关闭 terminal
- 支持全宽底部 terminal 面板

移动端:

- 支持单 terminal 全屏
- 支持 tabs 或横向 session chips
- 支持软键盘输入
- 支持常用控制键面板:
  - `Esc`
  - `Tab`
  - `Ctrl`
  - `Alt`
  - `Arrow`
  - `PgUp/PgDn`

TUI 支撑关键点:

- 必须把终端渲染交给终端模拟器 widget
- resize 事件必须在布局变化时上送
- 不做输入法层面的“逐行提交”，而是按键/文本流发送

## 6.9 Shell 选择与平台策略

建议默认 shell:

- macOS/Linux:
  - 优先读取用户环境中的默认 shell
  - fallback 到 `/bin/zsh` 或 `/bin/bash`
- Windows:
  - 未来支持 `powershell.exe` / `pwsh.exe`

由于当前仓库里 `desktop-server` 的桌面采集能力明显偏向 macOS/Linux，本阶段 terminal MVP 建议优先落地:

- macOS
- Linux

Windows 纳入设计，但不作为第一阶段验收前提。

## 7. 推荐实施顺序

## Phase 1: 品牌主题与登录页

- 建立统一主题与 glass 组件
- 重做 desktop/mobile 登录页

## Phase 2: 桌面端主页与授权弹窗

- 重构 `desktop_app` 登录后布局
- 引入控制台首页
- 将授权请求改为 modal

## Phase 3: 移动端主页与屏幕切换

- 重构 mobile 工作台
- 将屏幕切换改为 overlay

## Phase 4: Terminal 协议与服务端能力

- backend terminal session 模型
- desktop-server PTY manager
- backend relay ws
- 本地 ws 扩展

## Phase 5: Flutter Terminal UI

- 新建 `feature_terminal`
- 桌面端 terminal 面板
- 移动端 terminal 页面

## Phase 6: 联调与体验修整

- ANSI/TUI 验证
- resize 验证
- 移动端软键盘与控制键修整
- 断线重连与会话关闭体验

## 8. 风险与注意点

- `BackdropFilter` 叠在远程视频大面积区域会有性能成本，需控制使用范围
- 参考稿中的授权弹窗字段目前后端并不完整，若想做到同等信息密度，需要补协议
- 当前 `app_theme.dart` 太薄，若直接在各页面硬编码颜色，后续会很难维护
- Terminal 若走普通文本协议，将无法稳定支持 `vim`, `htop`, `top`, `less` 等 TUI，必须走 PTY + 终端模拟器
- backend 现有 event bus 更适合事件，不适合高频 terminal 字节流，必须新增专用 relay

## 9. 本次 review 需要你确认的点

- 桌面端主页上半区是否接受“设备状态 + 屏幕缩略图 + 授权概览”的映射方案，而不是做成本机实时大预览
- Terminal 第一阶段是否按 macOS/Linux 先验收，Windows 作为后续支持
- 授权弹窗若先只展示当前已有字段，是否可以接受；更细信息后续再补协议

## 10. 预计改动范围

Flutter:

- `client/packages/app_core/lib/src/theme/app_theme.dart`
- `client/apps/desktop_app/lib/main.dart`
- `client/apps/mobile_app/lib/main.dart`
- `client/packages/feature_auth/lib/src/auth_page.dart`
- `client/packages/feature_device_list/lib/src/device_list_page.dart`
- `client/packages/feature_remote_view/lib/src/remote_view_page.dart`
- `client/packages/feature_remote_view/lib/src/remote_view_state.dart`
- `client/packages/feature_remote_view/lib/src/remote_view_view_model.dart`
- `client/packages/feature_desktop_authorize/lib/src/desktop_authorize_page.dart`
- `client/packages/feature_desktop_authorize/lib/src/desktop_authorize_state.dart`
- `client/packages/feature_desktop_authorize/lib/src/desktop_authorize_view_model.dart`
- 新建 `client/packages/feature_terminal/...`
- `client/packages/infra_api/...`

backend-server:

- migration 新增 terminal 表
- `backend-server/src/api/...`
- `backend-server/src/application/...`

desktop-server:

- `desktop-server/src/api/ws.rs`
- 新建 `desktop-server/src/terminal/...`
- `desktop-server/src/app/...`

## 11. 结论

这套需求可以拆成两条线:

- UI 线: 基本都是现有 Flutter 页面重构，风险可控
- Terminal 线: 属于新能力建设，需要同时改 Flutter、backend-server、desktop-server 和协议

其中登录页半透明效果可做，不建议因为实现难度放弃。真正需要先评审的是 Terminal 的协议边界和桌面端主页的信息映射方式。
