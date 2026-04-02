import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

class AppLocalizations {
  AppLocalizations(this.locale);

  final Locale locale;
  static AppLocalizations current = AppLocalizations(const Locale('zh'));

  static const supportedLocales = [
    Locale('zh'),
    Locale('en'),
  ];

  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates = [
    _AppLocalizationsDelegate(),
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ];

  static AppLocalizations of(BuildContext context) {
    final localizations = Localizations.of<AppLocalizations>(context, AppLocalizations);
    assert(localizations != null, 'AppLocalizations not found in context');
    return localizations!;
  }

  bool get isZh => locale.languageCode.toLowerCase().startsWith('zh');

  String get freeloom => isZh ? 'Freeloom' : 'Freeloom';
  String get desktopTitle => isZh ? 'Freeloom Console' : 'Freeloom Console';
  String get mobileTitle => isZh ? 'Freeloom Remote' : 'Freeloom Remote';
  String get loginPanelTitle => isZh ? '欢迎回来' : 'Welcome back';
  String get loginPanelSubtitle =>
      isZh ? '输入凭据后即可进入远程工作台。' : 'Enter your credentials to access the workspace.';
  String get secureWorkspaceEntry =>
      isZh ? '安全远程协作入口' : 'Secure remote collaboration entry';
  String get mobileWorkspaceEntry =>
      isZh ? '移动端远程工作台入口' : 'Mobile remote workspace entry';
  String get accountIdentity => isZh ? '账号标识' : 'Account identity';
  String get accessCredential => isZh ? '访问凭据' : 'Access credential';
  String get usernameHint => isZh ? 'operator@freeloom.local' : 'operator@freeloom.local';
  String get passwordHint => isZh ? '请输入密码' : 'Enter your password';
  String get login => isZh ? '登录' : 'Sign in';
  String get register => isZh ? '注册' : 'Register';
  String get desktopLoginHint =>
      isZh ? '桌面端登录后可接收连接请求并创建真实终端会话。' : 'After signing in, the desktop can accept requests and create real terminal sessions.';
  String get mobileLoginHint =>
      isZh ? '移动端登录后可发起屏幕连接并接入共享终端。' : 'After signing in, mobile can start screen sessions and join shared terminals.';
  String get desktopFooterStatus =>
      isZh ? '桌面节点待命 | AES-256-GCM' : 'Desktop node ready | AES-256-GCM';
  String get mobileFooterStatus =>
      isZh ? '中心节点在线 | 延迟 14ms' : 'Central node active | Latency 14ms';
  String get authFooterAgreements =>
      isZh ? '访问此入口即表示你同意安全协议与隐私加密条款。' : 'By accessing this portal you agree to the security protocols and privacy encryption terms.';
  String get currentAccount => isZh ? '当前账号' : 'Current account';
  String get desktopAccountReady =>
      isZh ? '桌面控制台已在线，可继续处理授权请求、查看设备状态并创建终端。' : 'The desktop console is online and ready for approvals, device status, and terminal creation.';
  String get mobileAccountReady =>
      isZh ? '移动端已就绪，可切换设备、远程查看屏幕并连接共享终端。' : 'The mobile console is ready for device switching, remote viewing, and shared terminal access.';
  String get consolePageTitle => isZh ? '设备控制台' : 'Device console';
  String get authorizePageTitle => isZh ? '授权请求' : 'Authorization';
  String get terminalPageTitle => isZh ? '共享终端' : 'Shared terminal';
  String get accountPageTitle => isZh ? '账号信息' : 'Account';
  String get dashboardNav => isZh ? 'Dashboard' : 'Dashboard';
  String get terminalNav => isZh ? 'Terminal' : 'Terminal';
  String get authorizeNav => isZh ? 'Authorize' : 'Authorize';
  String get nodesNav => isZh ? 'Nodes' : 'Nodes';
  String get desktopConsoleSubtitle =>
      isZh ? '面向桌面设备侧的连接授权与远程终端控制台' : 'Desktop-side console for authorization and remote terminal workflows';
  String get logout => isZh ? '退出' : 'Logout';
  String get controlConsole => isZh ? '控制台' : 'Console';
  String get authorize => isZh ? '授权' : 'Authorize';
  String get terminal => isZh ? '终端' : 'Terminal';
  String get account => isZh ? '账号' : 'Account';
  String get desktopOperator => isZh ? '桌面操作员' : 'Desktop operator';
  String get desktopConnectedNodes => isZh ? 'CONNECTED: 4 NODES' : 'CONNECTED: 4 NODES';
  String get desktopNodeActive => isZh ? 'NODE-04 ACTIVE' : 'NODE-04 ACTIVE';
  String get primaryDisplayTitle => isZh ? 'PRIMARY DISPLAY' : 'PRIMARY DISPLAY';
  String get awaitingSync => isZh ? '等待同步' : 'Awaiting sync';
  String get standbyLabel => isZh ? 'Standby' : 'Standby';
  String get settingsLabel => isZh ? 'Settings' : 'Settings';
  String get supportLabel => isZh ? 'Support' : 'Support';
  String get logsLabel => isZh ? 'Logs' : 'Logs';
  String get latencyLabel => isZh ? 'LATENCY' : 'LATENCY';
  String get frameRateLabel => isZh ? 'FRAMERATE' : 'FRAMERATE';
  String get bitrateLabel => isZh ? 'BITRATE' : 'BITRATE';
  String get terminalCapabilityHint =>
      isZh ? '终端能力会与授权控制合并到同一桌面工作台。' : 'Terminal capability will live inside the same desktop workspace as authorization.';
  String get localWs => isZh ? '本地 WS' : 'Local WS';
  String get connected => isZh ? '已连接' : 'Connected';
  String get disconnected => isZh ? '未连接' : 'Disconnected';
  String get deviceRegistration => isZh ? '设备注册' : 'Device registration';
  String get sharingState => isZh ? '共享状态' : 'Sharing state';
  String get sharing => isZh ? '屏幕共享中' : 'Sharing';
  String get idle => isZh ? '待机' : 'Idle';
  String get pendingRequests => isZh ? '待处理请求' : 'Pending requests';
  String get active => isZh ? 'Active' : 'Active';
  String get desktopDeviceOverview => isZh ? '桌面设备概览' : 'Desktop device overview';
  String get desktopOverviewBody =>
      isZh ? '当前桌面侧负责接收连接请求、维护屏幕共享状态，并将在下一步承载真实 PTY 终端。' : 'The desktop currently handles connection requests and screen sharing state, and will also host the real PTY terminal.';
  String get waitingScreenShare => isZh ? '等待屏幕共享' : 'Waiting for screen sharing';
  String get screenSharingActive => isZh ? '当前桌面正在向移动端共享画面' : 'The desktop is actively sharing a screen to mobile';
  String get screenSharingIdle => isZh ? '当前未建立活跃共享' : 'No active screen share session';
  String get latestEvent => isZh ? '最近事件' : 'Latest event';
  String get localPort => isZh ? '本地端口' : 'Local port';
  String get currentUser => isZh ? '当前用户' : 'Current user';
  String get terminalWorkspace => isZh ? 'Terminal Workspace' : 'Terminal Workspace';
  String get terminalWorkspaceHint =>
      isZh ? '真实 PTY 终端会接到这里，与移动端共享同一会话、同一输出和同一输入通道。' : 'A real PTY terminal will appear here and share the same session, output, and input channel with mobile.';
  String get mobileReady => isZh ? '移动端远程工作台已就绪' : 'Mobile remote workspace is ready';
  String currentSessionLabel(String sessionId) =>
      isZh ? '当前会话 $sessionId' : 'Current session $sessionId';
  String get nodeSelectionTitle => isZh ? 'SELECT NODE' : 'SELECT NODE';
  String get nodeSelectionSubtitle =>
      isZh ? 'ACTIVE ORCHESTRATION MATRIX' : 'ACTIVE ORCHESTRATION MATRIX';
  String get noActiveSessionTitle =>
      isZh ? '当前尚未建立活动会话。' : 'No active sessions established.';
  String get noActiveSessionHint =>
      isZh ? '请选择一个节点以发起加密握手。' : 'Select a node to initiate an encrypted handshake.';
  String get noDeviceAvailable =>
      isZh ? '当前没有可用设备，请确认桌面端已登录并在线。' : 'No devices are available. Make sure the desktop side is signed in and online.';
  String get devices => isZh ? '设备' : 'Devices';
  String get monitors => isZh ? '监视器' : 'Monitors';
  String get sharedTerminal => isZh ? 'Shared Terminal' : 'Shared Terminal';
  String get sharedTerminalHint =>
      isZh ? '终端共享能力会在这里与桌面端共享同一个 PTY，会同步 ANSI 颜色、TUI 和输入输出。' : 'The shared terminal will attach to the same PTY as desktop, syncing ANSI colors, TUI, and bidirectional IO.';
  String get deviceListLoadFailed => isZh ? '设备列表加载失败' : 'Failed to load device list';
  String get updateDeviceSettingsFailed =>
      isZh ? '更新设备设置失败' : 'Failed to update device settings';
  String get connectRequestFailed => isZh ? '连接请求失败' : 'Connection request failed';
  String get desktopUnavailableHint =>
      isZh ? '桌面端当前不可接收连接，请确认 desktop-server 和授权页在线后重试' : 'The desktop cannot accept connections right now. Ensure desktop-server and the authorization UI are online.';
  String get version => isZh ? '版本' : 'Version';
  String get status => isZh ? '状态' : 'Status';
  String get online => isZh ? '在线' : 'Online';
  String get offline => isZh ? '离线' : 'Offline';
  String get autoApprove => isZh ? '自动授权' : 'Auto approve';
  String get connect => isZh ? '连接' : 'Connect';
  String get attachSession => isZh ? '附加会话' : 'Attach session';
  String get view => isZh ? '查看' : 'View';
  String get settings => isZh ? '设置' : 'Settings';
  String get remoteWorkspaceTitle => isZh ? 'REMOTE WORKSPACE' : 'REMOTE WORKSPACE';
  String get remoteWorkspaceIdleHint =>
      isZh ? '连接远端节点后，这里会显示请求状态、远程桌面和共享终端。' : 'Once you connect to a node, request state, remote desktop, and shared terminal will appear here.';
  String get remoteDesktopTitle => isZh ? 'Remote Desktop' : 'Remote Desktop';
  String get mainDisplayLabel => isZh ? 'MAIN DISPLAY' : 'MAIN DISPLAY';
  String get syncedLabel => isZh ? 'SYNCED' : 'SYNCED';
  String get selectNodeFirstHint =>
      isZh ? '请先回到节点列表选择一个在线节点。' : 'Go back to the node list and select an online node first.';
  String get session => isZh ? '会话' : 'Session';
  String get screen => isZh ? '屏幕' : 'Screen';
  String get notConnectedSession => isZh ? '未连接会话' : 'No active session';
  String get requestingAccessTitle => isZh ? 'REQUESTING ACCESS...' : 'REQUESTING ACCESS...';
  String get requestingAccessSubtitle =>
      isZh ? '等待主机侧授权确认...' : 'Waiting for authorization on host...';
  String get cancelRequest => isZh ? '取消请求' : 'Cancel request';
  String get requestLogHandshake =>
      isZh ? '正在与目标主机进行握手' : 'Handshaking with target host';
  String get requestLogValidated =>
      isZh ? '数据包校验完成' : 'Packet exchange validated';
  String get requestLogAwaitingManualApproval =>
      isZh ? '等待主机侧手动确认' : 'Awaiting manual host confirmation';
  String get selectActiveDisplayTitle =>
      isZh ? 'SELECT ACTIVE DISPLAY' : 'SELECT ACTIVE DISPLAY';
  String displayDetectedLabel(int count) =>
      isZh ? '检测到 $count 个显示器' : '$count displays detected';
  String waitingScreenFrame(String sessionId, String state) =>
      isZh ? '等待屏幕画面\n会话: $sessionId\n状态: $state' : 'Waiting for remote frame\nSession: $sessionId\nState: $state';
  String get recentEvent => isZh ? '最近事件' : 'Latest event';
  String get pauseDeadline => isZh ? '后台暂停截止时间' : 'Background pause deadline';
  String get autoQuality => isZh ? '自动码率' : 'Auto quality';
  String get snapshotRefresh => isZh ? '快照刷新' : 'Snapshot refresh';
  String get portraitView => isZh ? '竖屏查看' : 'Portrait';
  String get landscapeView => isZh ? '横屏查看' : 'Landscape';
  String get refreshScreenList => isZh ? '刷新屏幕列表' : 'Refresh screen list';
  String get simulateBackground => isZh ? '模拟后台' : 'Simulate background';
  String get backToForeground => isZh ? '回到前台' : 'Back to foreground';
  String get disconnectSession => isZh ? '断开会话' : 'Disconnect';
  String get exitLandscape => isZh ? '退出横屏' : 'Exit landscape';
  String get refresh => isZh ? '刷新' : 'Refresh';
  String get localDesktopConnected => isZh ? '已连接 desktop-server' : 'Connected to desktop-server';
  String get localDesktopDisconnected => isZh ? '未连接 desktop-server' : 'Disconnected from desktop-server';
  String get reconnect => isZh ? '重连' : 'Reconnect';
  String get realMediaSharing => isZh ? '真实媒体: 已共享屏幕' : 'Real media: screen shared';
  String get realMediaInitializing => isZh ? '真实媒体: 正在建立共享' : 'Real media: preparing screen share';
  String get realMediaIdle => isZh ? '真实媒体: 未开始共享' : 'Real media: idle';
  String get currentSharedScreen => isZh ? '当前共享屏幕' : 'Current shared screen';
  String get desktopAuthorizeIntro =>
      isZh ? '桌面端仅负责授权与推流，不再预览本机屏幕。' : 'The desktop client focuses on authorization and publishing instead of local preview.';
  String get autoApproveShare => isZh ? '自动授权屏幕共享' : 'Auto approve screen sharing';
  String get deviceLevelDefaultOff =>
      isZh ? '设备级设置，默认关闭' : 'Device-level setting, disabled by default';
  String get securityProtocolActive =>
      isZh ? 'SECURITY PROTOCOL: ACTIVE' : 'SECURITY PROTOCOL: ACTIVE';
  String get incomingConnectionRequest =>
      isZh ? 'INCOMING CONNECTION REQUEST' : 'INCOMING CONNECTION REQUEST';
  String get sourceDeviceLabel => isZh ? '源设备' : 'Source device';
  String get ipAddressLabel => isZh ? 'IP 地址' : 'IP address';
  String get protocolLabel => isZh ? '协议' : 'Protocol';
  String get timestampLabel => isZh ? '时间戳' : 'Timestamp';
  String get locationLabel => isZh ? '位置' : 'Location';
  String get authorizeAccess => isZh ? '授权访问' : 'Authorize access';
  String requestMetaLeft(String sessionId) =>
      isZh ? 'REQUEST ID: $sessionId' : 'REQUEST ID: $sessionId';
  String get requestMetaRight =>
      isZh ? 'SECURITY LAYER: 4 (ENCRYPTED)' : 'SECURITY LAYER: 4 (ENCRYPTED)';
  String requesterLabel(String requester) => isZh ? '请求者: $requester' : 'Requester: $requester';
  String targetDeviceLabel(String deviceName) => isZh ? '目标设备: $deviceName' : 'Target device: $deviceName';
  String sessionIdLabel(String sessionId) => isZh ? '会话ID: $sessionId' : 'Session ID: $sessionId';
  String get approve => isZh ? '授权' : 'Approve';
  String get reject => isZh ? '拒绝' : 'Reject';
  String get noPendingRequests => isZh ? '当前没有待授权请求' : 'No pending authorization requests';
  String get enterUsernamePassword =>
      isZh ? '请输入用户名和密码' : 'Please enter username and password';
  String get registerValidation =>
      isZh ? '用户名不能为空，密码至少8位' : 'Username is required and password must be at least 8 characters';
  String loginFailed(String error) => isZh ? '登录失败: $error' : 'Sign-in failed: $error';
  String registerFailed(String error) => isZh ? '注册失败: $error' : 'Registration failed: $error';
  String loadSnapshotsFailed(String error) =>
      isZh ? '加载屏幕快照失败: $error' : 'Failed to load screen snapshots: $error';
  String switchScreenFailed(String error) =>
      isZh ? '切换屏幕失败: $error' : 'Failed to switch screen: $error';
  String updateResolutionFailed(String error) =>
      isZh ? '更新分辨率失败: $error' : 'Failed to update resolution: $error';
  String autoQualityFailed(String error) =>
      isZh ? '切换自动码率失败: $error' : 'Failed to switch auto quality: $error';
  String pauseSessionFailed(String error) =>
      isZh ? '暂停会话失败: $error' : 'Failed to pause session: $error';
  String resumeSessionFailed(String error) =>
      isZh ? '恢复会话失败: $error' : 'Failed to resume session: $error';
  String connectDesktopFailed(String error) =>
      isZh ? '连接 desktop-server 失败: $error' : 'Failed to connect to desktop-server: $error';
  String get localConnectionUnavailable =>
      isZh ? '本地连接已断开，无法提交授权' : 'Local connection is offline, unable to submit authorization';
  String localConnectionError(String error) =>
      isZh ? '本地连接异常: $error' : 'Local connection error: $error';
  String eventChannelError(String error) =>
      isZh ? '事件通道异常: $error' : 'Event channel error: $error';
  String initWebrtcFailed(String error) =>
      isZh ? '初始化 WebRTC 失败: $error' : 'Failed to initialize WebRTC: $error';
  String connectionRejected(String reason) =>
      isZh ? '连接被拒绝: $reason' : 'Connection rejected: $reason';
  String handleRemoteOfferFailed(String error) =>
      isZh ? '处理远端 Offer 失败: $error' : 'Failed to handle remote offer: $error';
  String startScreenShareFailed(String error) =>
      isZh ? '启动屏幕共享失败: $error' : 'Failed to start screen sharing: $error';
  String applyRemoteCandidateFailed(String error) =>
      isZh ? '应用远端候选失败: $error' : 'Failed to apply remote candidate: $error';
  String switchSharedScreenFailed(String error) =>
      isZh ? '切换共享屏幕失败: $error' : 'Failed to switch shared screen: $error';
  String deviceRegistrationFailed(String error) =>
      isZh ? '设备注册失败: $error' : 'Failed to register device: $error';
  String syncAutoApproveFailed(String error) =>
      isZh ? '同步自动授权设置失败: $error' : 'Failed to sync auto-approve setting: $error';
  String terminalLoadFailed(String error) =>
      isZh ? '加载终端列表失败: $error' : 'Failed to load terminals: $error';
  String terminalCreateFailed(String error) =>
      isZh ? '创建终端失败: $error' : 'Failed to create terminal: $error';
  String terminalCloseFailed(String error) =>
      isZh ? '关闭终端失败: $error' : 'Failed to close terminal: $error';
  String get terminalStreamUnavailable =>
      isZh ? 'Mock 模式下未启用 terminal websocket' : 'Terminal websocket is unavailable in mock mode';
  String terminalConnectFailed(String error) =>
      isZh ? '连接终端失败: $error' : 'Failed to connect to terminal: $error';
  String terminalStreamError(String error) =>
      isZh ? '终端流异常: $error' : 'Terminal stream error: $error';
  String get createTerminal => isZh ? '创建终端' : 'Create terminal';
  String get noTerminalSession => isZh ? '暂无终端会话' : 'No terminal session';
  String get noTerminalSessionHint =>
      isZh ? '可以从当前设备创建一个新的共享 PTY 终端。' : 'Create a new shared PTY terminal for this device.';
  String get terminalTargetMissing =>
      isZh ? '当前还没有绑定远端设备，暂时无法创建终端。' : 'No target device is bound yet, so a terminal cannot be created.';
  String get terminalStable => isZh ? 'CONNECTION STABLE' : 'CONNECTION STABLE';
}

class _AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) =>
      AppLocalizations.supportedLocales.any((item) => item.languageCode == locale.languageCode);

  @override
  Future<AppLocalizations> load(Locale locale) async {
    final localizations = AppLocalizations(locale);
    AppLocalizations.current = localizations;
    return localizations;
  }

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

extension AppLocalizationsContext on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}
