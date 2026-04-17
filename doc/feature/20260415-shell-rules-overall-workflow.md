# Shell Rules 整体工作流程

## 功能说明

本文档单独说明 Sirix 当前 Shell Rules 的完整工作链路，重点回答下面几个问题：

- Shell Rules 分别从哪里配置、保存到哪里
- Shell Rules 在启动 AI Session 时如何计算生效结果
- Agent 级 Shell Rules、全局规则、工作区规则、Session 临时规则之间如何叠加
- 运行时出现 Shell 授权弹层后，用户的决定如何写回对应作用域
- 新规则写回后，当前 Session 如何立即生效

这份文档只聚焦 Shell Rules，不再混写 Agent 切换、Tool Rules、MCP、Skills、fallback model 等其它能力。

## 代码位置

- `desktop-server/src/app/ai/config.rs`
  - 定义 `ShellRulesConfig`
  - 负责全局 / 工作区 Shell Rules 的读取、保存、归并和规范化
  - 负责在 Session 启动前计算某个 Agent 的最终生效 Shell Rules
- `desktop-server/src/app/ai/session.rs`
  - 保存 Session 级临时 Shell Rules
  - 在 Session 启动和重配置时把最终规则写入 exec policy 文件
- `desktop-server/src/api/ai.rs`
  - 暴露 `/ai/shell-rules`
  - 暴露 `/ai/sessions/:ai_session_id/shell-rules/resolve`
  - 负责把运行时授权决定写回 `session / workspace / global`
- `client/packages/feature_settings_ai/lib/src/sections/shell_rules_settings_section.dart`
  - 全局 Shell Rules 设置页
  - 编辑全局 `mode / allow / deny`
- `client/packages/feature_settings_ai/lib/src/sections/agent_settings_section.dart`
  - `Edit Agent` 中的 Agent Shell Rules 编辑区
  - 编辑 Agent 级 `allow / deny` 前缀，以及 Agent 自身 `approvalMode`
- `client/packages/infra_api/lib/src/ai_models.dart`
  - Flutter 侧 `ShellRulesConfigModel`、`AgentConfigModel.shellRules`

## 核心配置对象

### 1. `ShellRulesConfig`

`ShellRulesConfig` 包含 3 组关键字段：

- `mode`
  - `allow / ask / deny`
  - 用于决定 Shell 授权的基准模式
- `allow`
  - 允许的命令前缀列表
- `deny`
  - 禁止的命令前缀列表

全局规则和工作区规则都使用这套结构。

### 2. Agent 相关字段

Agent 有两块与 Shell 授权相关的配置：

- `approval_mode`
  - Agent 自己的 Shell 授权模式
  - 若 Agent 设成 `allow` 或 `deny`，会直接覆盖 Session 最终 `shell_mode`
  - 若 Agent 设成 `ask`，则继续使用最终合并后的 Shell Rules `mode`
- `shell_rules`
  - Agent 级 `allow / deny` 前缀覆盖层
  - 只覆盖前缀，不重置全局 / 工作区已经确定的 `mode`

这个拆分非常重要：

- `approval_mode` 负责“当前 Agent 默认以什么授权模式运行”
- `shell_rules` 负责“当前 Agent 额外放宽或收紧哪些命令前缀”

## 配置来源与落盘位置

### 1. 全局规则

全局 Shell Rules 落在：

- `~/.sirix/shell-rules.json`

主要入口：

- 桌面端 AI 设置页的 `Shell Rules` 独立分组
- 本地 API `GET /ai/shell-rules`
- 本地 API `PATCH /ai/shell-rules`

这层是所有工作区、所有 Agent 的基础默认值。

### 2. 工作区规则

工作区 Shell Rules 落在：

- `<workspace>/.sirix/shell-rules.json`

当前工作区规则不在设置页中长期编辑，而是主要通过运行时授权弹层写回：

- 用户在 Shell 授权弹层中选择 `Allow workspace` 或 `Deny workspace`
- desktop-server 调用 `load_workspace_shell_rules`
- 更新对应前缀后调用 `save_workspace_shell_rules`

这层只对当前工作区生效。

### 3. Agent 规则

Agent 级 Shell Rules 保存在全局 AI 配置 `config.toml` 的 Agent 定义中，不单独存 JSON 文件。

编辑入口：

- AI 设置页 `Agents`
- `Edit Agent`
- `Agent Shell Rules`

这层规则跟随 Agent profile 一起保存，属于 Agent 本身的运行时约束。

### 4. Session 临时规则

Session 级 Shell Rules 不持久化到全局配置文件，也不写入工作区配置文件，而是保存在 desktop-server 的 Session Registry 内存态中：

- `AiSessionRegistry.push_session_shell_rule`

这层只对当前正在运行的 AI Session 生效，Session 结束后失效。

## 规则优先级

当前完整优先级为：

1. 全局规则
2. Agent 规则
3. 工作区规则
4. Session 临时规则

冲突时，后者覆盖前者。

具体语义：

- Agent 规则先覆盖全局规则
- 工作区规则再覆盖全局与 Agent 规则
- Session 规则最后覆盖前三层

其中有一个关键实现细节：

- 全局 / 工作区合并使用 `merge_shell_rules`
  - 会同时合并 `mode / allow / deny`
- Agent / Session 合并使用 `merge_shell_rule_prefixes`
  - 只合并 `allow / deny`
  - 不会把已确定的共享 `mode` 被默认 `ask` 意外重置

这样做的原因是：

- 工作区本来就应该能在最后覆盖共享 `mode`
- Agent 和 Session 只应补充前缀控制，不应无意改变共享默认模式

## 规则规范化与前缀归并

Sirix 在保存和加载 Shell Rules 时会统一做规范化：

- 去掉空行
- 统一按空白切分命令前缀
- 去重
- 做前缀归并

前缀归并的意思是：

- 如果已经存在更粗的允许前缀，例如 `git`
- 再加入更细的允许前缀，例如 `git status`
- 更细前缀会被视为冗余，不再单独保留

反过来：

- 如果后来加入一个更粗前缀
- 已存在的更细前缀也会被收敛掉

另外还有一个关键冲突规则：

- 如果更高优先级层新增了相反方向的更粗前缀，例如高层 `deny = ["find"]`
- 低优先级层里被它完整覆盖的反向前缀，例如 `allow = ["find . -name"]`
- 会在合并时被移除

这样才能满足“高优先级的更粗规则覆盖低优先级的更细规则”的权限语义。

这样可以避免规则文件不断膨胀，也可以让规则语义更稳定。

## 从设置页到落盘的流程

### 1. 编辑全局 Shell Rules

用户进入 AI 设置页的 `Shell Rules` 分组后，可以编辑：

- `mode`
- `allow`
- `deny`

保存流程：

1. Flutter 把表单内容组装成 `ShellRulesConfigModel`
2. `AiSettingsViewModel.save()` 调用本地 API `PATCH /ai/shell-rules`
3. desktop-server 调用 `save_global_shell_rules`
4. 最终写入 `~/.sirix/shell-rules.json`

### 2. 编辑 Agent Shell Rules

用户进入 `Agents -> Edit Agent` 后，可以编辑：

- `approvalMode`
- `Agent Shell Rules.allow`
- `Agent Shell Rules.deny`

保存流程：

1. Flutter 把表单内容组装进 `AgentConfigModel`
2. 整个 `SirixAiConfig` 通过 `PATCH /ai/config` 保存
3. desktop-server 对配置做 `normalized_sirix_config`
4. Agent 的 `shell_rules` 最终保存在 `~/.sirix/config.toml`

也就是说：

- 全局 Shell Rules 单独走 `shell-rules.json`
- Agent Shell Rules 跟随 Agent 一起走 `config.toml`

## Session 启动时的生效流程

当用户启动一个 AI Session 时，Shell Rules 会按下面顺序进入运行时：

1. desktop-server 先解析当前工作区的有效 AI 配置
2. 选中当前 Agent
3. 读取全局 Shell Rules
4. 先叠加当前 Agent 的 `shell_rules`
5. 如果当前工作区存在 `.sirix/shell-rules.json`，再叠加工作区规则
6. 再叠加当前 Session 的临时 Shell Rules
7. 得到最终 `effective_shell_rules`

随后会分成两部分写入运行时：

### 1. 写 Session runtime 文件

desktop-server 调用：

- `build_session_agent_runtime`

该步骤会生成：

- `agent_id`
- `shell_mode`
- `builtin_tool_ids`

其中 `shell_mode` 计算规则是：

- 如果 Agent `approval_mode = allow`，最终 `shell_mode = allow`
- 如果 Agent `approval_mode = deny`，最终 `shell_mode = deny`
- 如果 Agent `approval_mode = ask`，最终 `shell_mode = effective_shell_rules.mode`

### 2. 写 exec policy 文件

desktop-server 调用：

- `write_session_exec_policy_file`

这个步骤会把最终 `allow / deny` 前缀写成当前 Session 的 exec policy 文件，供运行中的 CLI / runtime 实际拦截命令时使用。

因此最终真正影响运行时行为的是两部分：

- `shell_mode`
- exec policy 文件中的 `allow / forbidden` 前缀规则

## 运行时授权弹层的回写流程

当运行中的 Session 触发 Shell 授权弹层后，用户可能会做两类决定：

- 单次决定
- 持久化到某个作用域的决定

### 1. 单次决定

例如：

- `Allow once`
- `Deny once`

这类决定只影响当前这次授权，不会写入 Sirix 的全局、工作区或 Session 规则存储。

### 2. 持久化决定

例如：

- `Allow session`
- `Deny session`
- `Allow workspace`
- `Deny workspace`
- `Allow global`
- `Deny global`

这类决定会经过本地 API：

- `POST /ai/sessions/:ai_session_id/shell-rules/resolve`

请求体会带上：

- 当前 Session id
- 决策类型 `allow / deny`
- 目标 scope `session / workspace / global`
- 用户最终确认的命令前缀

desktop-server 收到后按 scope 分流：

### `session`

1. 调用 `AiSessionRegistry.push_session_shell_rule`
2. 只更新当前 Session 的内存态 `session_shell_rules`
3. 不写磁盘

### `workspace`

1. 调用 `load_workspace_shell_rules`
2. 将前缀写入当前工作区 `.sirix/shell-rules.json`
3. 调用 `save_workspace_shell_rules`

### `global`

1. 调用 `load_global_shell_rules`
2. 将前缀写入 `~/.sirix/shell-rules.json`
3. 调用 `save_global_shell_rules`

在写回时，Sirix 会先移除对立列表中的同名前缀，再写入目标列表：

- `allow` 前会先从 `deny` 删除
- `deny` 前会先从 `allow` 删除

这样可以避免同一个前缀同时出现在 allow 和 deny 中。

## 写回后的热更新流程

无论规则写回到 `session / workspace / global` 的哪一层，desktop-server 都会继续执行：

- `reconfigure_ai_session_agent(...)`

这一步的目的不是切 Agent，而是重新基于当前 Agent 计算一次运行时文件，让新规则立刻生效。

热更新后的结果包括：

- 重新计算当前 Session 的 `shell_mode`
- 重新生成当前 Session 的 exec policy 文件
- 让当前 Session 后续的 Shell 请求按最新规则执行

因此用户不需要手动重开 Session，就可以看到：

- 新增的 allow 前缀立即跳过授权
- 新增的 deny 前缀立即被阻止

## 整体时序总结

把整个 Shell Rules 链路按时间顺序串起来，可以归纳成下面 8 步：

1. 用户在设置页编辑全局规则，或在 `Edit Agent` 中编辑 Agent 规则
2. 配置分别落盘到 `shell-rules.json` 或 `config.toml`
3. 用户启动 AI Session
4. desktop-server 读取全局、工作区、Agent、Session 四层规则并完成合并
5. desktop-server 产出 `shell_mode` 和 exec policy 文件
6. 运行中的 CLI / runtime 根据这些结果决定某条命令是直接放行、弹授权还是直接阻止
7. 若用户在授权弹层选择持久化 scope，desktop-server 把前缀写回对应层级
8. desktop-server 立即重建当前 Session 的运行时规则文件，保证新规则马上生效

## 当前约束

- 全局规则有独立设置页，工作区规则目前主要通过运行时授权弹层写入
- Agent 规则当前只提供前缀 allow/deny 覆盖，不单独提供 Agent 专属 `mode` 字段；Agent 的模式控制仍然走 `approval_mode`
- Session 规则是内存态，不跨 Session 持久化
- Agent / Session 规则只覆盖前缀，不覆盖全局 / 工作区已经确定的 `mode`

## 结论

Sirix 当前的 Shell Rules 不是单一配置文件，而是一套分层工作流：

- 全局规则负责共享默认值
- 工作区规则负责项目级覆盖
- Agent 规则负责 profile 级覆盖
- Session 规则负责本次运行的临时记忆

真正让它生效的关键不是“把规则存下来”，而是：

- 在 Session 启动前完成多层合并
- 在运行时把结果写成 `shell_mode + exec policy`
- 在用户授权后立即重建当前 Session 的运行时文件

这样才能保证设置页、授权弹层和实际命令执行行为保持一致。
