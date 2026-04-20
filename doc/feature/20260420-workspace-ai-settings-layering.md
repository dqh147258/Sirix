# Workspace AI Settings 分层与叠加规则

## 功能说明
本轮为 Desktop AI Settings 增加了 Global Settings / Workspace Settings 两套配置面，并明确了两类不同的合并规则：

1. **资源目录类配置走加法叠加**
   - `skills`
   - `mcp_servers`
   - `agents`

   规则为：
   - Global 配置始终生效
   - Workspace 可以新增同类资源
   - Workspace 若使用相同 `id`，则覆盖该 `id` 对应的 Global 定义

2. **Permissions / Agent Permissions 继续走优先级叠加**
   - Global Permissions
   - Agent Permissions
   - Workspace Permissions
   - Session Runtime 决策

   即资源是“补充式目录”，权限是“按层覆盖”的审批策略。

## 代码位置

### Desktop / Flutter
- `client/apps/desktop_app/lib/main.dart`
- `client/packages/feature_settings_ai/lib/src/ai_settings_page.dart`
- `client/packages/feature_settings_ai/lib/src/ai_settings_state.dart`
- `client/packages/feature_settings_ai/lib/src/ai_settings_view_model.dart`
- `client/packages/feature_settings_ai/lib/src/sections/skills_settings_section.dart`
- `client/packages/feature_settings_ai/lib/src/sections/mcp_settings_section.dart`
- `client/packages/feature_settings_ai/lib/src/sections/agent_settings_section.dart`
- `client/packages/feature_settings_ai/lib/src/sections/shell_rules_settings_section.dart`
- `client/packages/feature_settings_ai/lib/src/settings_ui.dart`
- `client/packages/infra_api/lib/src/ai_models.dart`
- `client/packages/infra_api/lib/src/desktop_local_client.dart`

### Desktop Server / Rust
- `desktop-server/src/api/ai.rs`
- `desktop-server/src/api/mod.rs`
- `desktop-server/src/app/ai/config.rs`

## 实现方法

### 1. 页面结构拆分
- 桌面端导航新增：
  - `Global Settings`
  - `Workspace Settings`
- `AiSettingsPage` 新增 `AiSettingsScope`，根据 scope 切换加载逻辑、可见 section、保存行为和头部文案。

### 2. Workspace 目标选择
- Workspace Settings 支持：
  - 最近工作区列表
  - 文件系统目录选择
- Desktop Server 会统一做 workspace root 归一化，避免直接选择 `.sirix` 目录、符号链接目录、或不同平台路径形式时出现歧义。

### 3. 资源目录加法合并
- Desktop Server 在 `merge_sirix_config` 中把：
  - `skills`
  - `mcp_servers`
  - `agents`

  从原本“空则继承 / 非空则整体替换”改成“按 id 合并”：
  - Global 保留
  - Workspace 新增项追加
  - Workspace 同 id 项覆盖

- Flutter 侧新增 `effectiveEditableConfig / visibleSkills / visibleMcpServers / visibleAgents`，让 Workspace 页面展示的是当前生效视图，而不是仅展示 workspace overlay 原始内容。

### 4. Permissions 与 Agent Permissions 的层级保持不变
- Workspace `Permissions` 页继续编辑 workspace 级 capability rules。
- Agent 编辑器中的 Builtin / Skill / MCP permission override 仍然作为 agent 级配置存在。
- 在 Workspace scope 下，Agent 编辑器会把 workspace permission layer 作为只读锁定层展示，提醒用户最终优先级仍是：
  `Global -> Agent -> Workspace -> Session`

### 5. Workspace 页面中的来源标识
- 针对 Skills / MCP Servers / Agents，前端根据当前项来源显示：
  - `Global`
  - `Workspace`
  - `Workspace Override`

- 对 Global-only 项：
  - 可在 Workspace 页面直接编辑，编辑后会形成 workspace override
  - 不能直接“删除 Global 本体”

- 对 Workspace-owned 项：
  - 可以删除，删除后会回退到 Global 定义（如果 Global 中存在同 id）

### 6. 接口与校验补强
- 新增 Workspace Settings 相关接口：
  - recent workspaces
  - workspace settings load/save
  - workspace select
- 对无效 workspace path 的读取/保存，改为返回 4xx 语义错误，而不是泛化为 server/internal 类错误。
- 客户端补充 Windows drive root / UNC root 路径保护，避免把 `C:\` 错误裁剪成 `C:`。

### 7. 测试与验证
- Rust 侧新增/保留了 workspace 相关测试：
  - `.sirix` 目录归一化
  - recent workspace 去重与截断
  - workspace config 不写入 global-only `cli/providers`
  - `.codex` 仅作为 metadata，不参与 Sirix 生效配置
  - workspace 资源目录以加法方式叠加 global 资源

## 规则总结

### 资源定义
- `skills / mcp_servers / agents`：**Global 一直生效，Workspace 负责补充或同 id 覆盖**

### 权限策略
- `Permissions / Agent Permissions`：**按层叠加，后层优先**

这保证了：
- Workspace 不需要先“复制” Global 资源才能使用它们
- 同时又保留了审批策略的层级覆盖能力
