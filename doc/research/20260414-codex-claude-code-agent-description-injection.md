# Codex 与 Claude Code：Agent 使用说明和功能说明如何注入到系统提示词、Function Call 与 MCP

## 1. 研究目标

本文回答两个问题：

1. `Codex` 和 `Claude Code` 是如何定义 Agent 的“功能说明”和“使用说明”的
2. 这些说明最终分别进入了哪一层：
   - 系统提示词
   - Function Call / Tool Schema
   - MCP 相关描述

这里特别区分两类文本：

- `功能说明`
  说明某个 Agent 是干什么的、擅长什么、有哪些限制
- `使用说明`
  说明主 Agent 什么时候该调用它、如何调用它、是否允许并行、如何等待结果、如何写 prompt

## 2. 结论先说

### 2.1 Codex

Codex 采用“两段注入”：

1. 把 `Agent 角色说明 + 使用规则` 注入到 `spawn_agent` 这个 function tool 的 `description` 和 `agent_type` 参数描述里
2. 把 `spawn 后的协作语义` 注入到子 Agent 的 `developer_instructions` 里

换句话说：

- 主 Agent 决策时，靠的是 `Function Call schema` 里的说明
- 子 Agent 真正运行时，靠的是 `developer_instructions`
- MCP 在 Codex 里主要负责“工具命名空间和 server instructions”，不是承载 Agent 说明本体

### 2.2 Claude Code

Claude Code 采用“三段注入”：

1. 把 `Agent 列表 + whenToUse + 调用规则` 注入到 `AgentTool` 的 `prompt()/description()` 中
2. 把 `具体 Agent 的系统职责` 注入到该 Agent 自己的 `getSystemPrompt()`
3. 用 `MCP 可用性` 和 `agent frontmatter.mcpServers` 去影响 Agent 是否展示、是否加载额外 MCP 工具

换句话说：

- 主 Agent 决策时，靠的是 `AgentTool` 描述文本
- 子 Agent 执行时，靠的是该 Agent 的 `system prompt`
- MCP 不直接存放“Agent 使用说明”，但会决定某些 Agent 是否可见、是否可运行、以及运行时有哪些工具

## 3. Codex：注入机制

### 3.1 Agent 说明的定义来源

Codex 的 Agent 说明主要来自两个地方：

### A. 内置 role 声明

源码位置：

- `codex-rs/core/src/agent/role.rs`

这里的 `spawn_tool_spec::build()` 会把内置和用户配置的 role 组装成一段文本。

内置 role 目前重点有：

- `default`
- `explorer`
- `worker`

其中 `explorer` 和 `worker` 的说明写得非常具体，例如：

- `explorer`：适合问具体代码库问题，强调 fast、authoritative、well-scoped、可并行多个 explorer
- `worker`：适合执行实现任务，强调文件 ownership、不要覆盖别的 worker 改动

这部分本质上就是 Codex 的 `Agent 功能说明 + 调用策略说明`。

### B. 用户自定义 role 文件

源码位置：

- `codex-rs/core/src/config/agent_roles.rs`
- `codex-rs/core/src/agent/role.rs`

用户可以通过 role config file 或 `agents.roles` 配置把 description、nickname_candidates、role config 注入进来。

也就是说，Codex 的 role 不是写死在 prompt 里的，而是配置层对象。

### 3.2 如何进入 Function Call

源码路径：

- `codex-rs/core/src/tools/spec.rs`
- `codex-rs/tools/src/tool_registry_plan.rs`
- `codex-rs/tools/src/tool_registry_plan_types.rs`
- `codex-rs/tools/src/agent_tool.rs`

注入链路如下：

1. `spec.rs` 里调用 `crate::agent::role::spawn_tool_spec::build(...)`
2. 生成 `default_agent_type_description`
3. 再通过 `ToolRegistryPlanParams.default_agent_type_description` 传给 tool registry
4. `tool_registry_plan.rs` 中构造 `SpawnAgentToolOptions`
5. `agent_tool.rs` 中把这段文本塞进 `spawn_agent` 的 `agent_type` 参数描述里

关键点：

- `spawn_agent_common_properties_v1/v2()` 中，`agent_type` 参数 description 直接使用 `agent_type_description`
- `spawn_agent_tool_description()` 还会把更高层的使用规则拼到整个 tool 的 description 上

因此在 Codex 里：

- “有哪些 agent role、各自适合干什么”会进入 `spawn_agent.agent_type` 的参数说明
- “什么时候才能 spawn、如何委派、怎么并行、何时 wait”会进入 `spawn_agent` 整个 tool 的说明

这属于典型的 `Function Call schema 注入`。

### 3.3 如何进入子 Agent 的系统提示词

源码路径：

- `codex-rs/core/src/tools/handlers/multi_agents_v2/spawn.rs`

在真正 spawn 时，Codex 会做两件事：

### A. 先把 role 配置层应用到子 Agent config

调用：

- `apply_role_to_config(&mut config, role_name)`

这个动作不是“拼一段自然语言提示”，而是把 role 对应的配置层覆写到子 Agent config 上。

它会影响：

- model
- reasoning effort
- profile/provider
- developer instructions 等配置项

这意味着 Codex 的 role 不只是提示词模板，更像“运行配置模板”。

### B. 再拼接统一的 spawned-agent developer instructions

同文件里定义了：

- `SPAWN_AGENT_DEVELOPER_INSTRUCTIONS`

这段文本会被追加到：

- `config.developer_instructions`

内容重点包括：

- 你是 newly spawned agent
- 你处在 team of agents 中
- 可以继续 spawn sub-agents
- 最终回答会回传给 parent
- forked history 只是背景，不是当前任务本体

因此在 Codex 中，子 Agent 的系统语义来源是：

1. role config 层
2. 统一的 spawn developer instructions

也就是说，Codex 在运行态真正影响子 Agent 行为的关键载体，不是 function description，而是 `developer_instructions`。

### 3.4 MCP 在 Codex 里扮演什么角色

源码路径：

- `codex-rs/core/src/tools/spec.rs`
- `codex-rs/tools/src/tool_registry_plan.rs`
- `codex-rs/tools/src/tool_registry_plan_types.rs`
- `codex-rs/tools/src/responses_api.rs`

Codex 中 MCP 相关信息会进入两层：

### A. MCP 工具本身的 function description

`mcp_tool_to_responses_api_tool()` 会把 MCP tool 转成 Responses API tool。

也就是说，MCP 工具自己的 name / description / input schema 会进入 tool schema。

### B. MCP server instructions 进入 namespace description

`spec.rs` 里会把：

- `tool.callable_namespace`
- `tool.server_instructions`

映射成 `ToolNamespace`

之后在 `tool_registry_plan.rs` 中又会转成：

- `ToolNamespaceDescription`

这个主要用于 code mode / namespace 级工具说明。

结论：

- Codex 的 MCP 说明是“工具命名空间说明”
- 它不是用来承载 `explorer/worker` 这种 Agent 角色说明的
- Agent 说明主体仍在 `spawn_agent schema + developer_instructions`

## 4. Claude Code：注入机制

### 4.1 Agent 说明的定义来源

Claude Code 的 Agent 定义来源明显分层。

### A. 内置 Agent

源码路径：

- `src/tools/AgentTool/builtInAgents.ts`
- `src/tools/AgentTool/built-in/*.ts`

内置 Agent 的典型字段有：

- `agentType`
- `whenToUse`
- `tools` / `disallowedTools`
- `model`
- `getSystemPrompt()`
- `requiredMcpServers`
- `mcpServers`

例如：

- `Explore`
- `Plan`
- `general-purpose`
- `verification`

其中：

- `whenToUse` 是主 Agent 选型时看的说明
- `getSystemPrompt()` 是该 Agent 运行时真正吃到的系统提示词

### B. 自定义 Agent

源码路径：

- `src/tools/AgentTool/loadAgentsDir.ts`
- `src/utils/markdownConfigLoader.ts`

Claude Code 支持从：

- JSON
- Markdown frontmatter + markdown body

加载自定义 Agent。

Markdown Agent 的关键映射关系是：

- `frontmatter.name` -> `agentType`
- `frontmatter.description` -> `whenToUse`
- markdown 正文 -> `getSystemPrompt()` 返回值
- `frontmatter.tools/disallowedTools/model/mcpServers/hooks/skills/...` -> 运行配置

这点很关键：

- `description` 不是系统提示词，它是“如何选择这个 agent”的说明
- markdown 正文才是该 agent 运行时的系统提示词

### 4.2 如何进入 Function Call / Tool Description

源码路径：

- `src/tools/AgentTool/AgentTool.tsx`
- `src/tools/AgentTool/prompt.ts`

Claude Code 不像 Codex 那样把每个 role 直接塞进某个 `agent_type` 参数 description。

它的做法是：

1. `AgentTool.prompt()` 在运行时取当前可用 agent 列表
2. 调用 `getPrompt(filteredAgents, isCoordinator, allowedAgentTypes)`
3. 生成整个 `AgentTool` 的说明文本

这段说明文本里会包含：

- `Launch a new agent...`
- 当前有哪些 agent type
- 每个 agent 的 `whenToUse`
- 每个 agent 的工具范围
- 使用规则、示例、何时不用 AgentTool

也就是说，Claude Code 把 Agent 使用说明主要放在：

- `AgentTool` 的整体 prompt/description 文本

不是放在某个单独参数的长 description 里。

### 4.3 Agent 列表文本如何生成

源码路径：

- `src/tools/AgentTool/prompt.ts`

这里有两个关键函数：

### A. `formatAgentLine(agent)`

它会把 agent 格式化为：

- `- type: whenToUse (Tools: ...)`

因此 `whenToUse` 是直接进入主 Agent 可见说明文本的核心字段。

### B. `getPrompt(agentDefinitions, isCoordinator, allowedAgentTypes)`

它负责拼完整的 AgentTool 说明，其中包括：

- 当前可用 agent 列表
- 如果启用了 fork，还会出现 `When to fork`
- `Writing the prompt`
- 示例
- 非 coordinator 模式下的 usage notes

换句话说，Claude Code 的“如何使用 Agent”几乎都集中在 `AgentTool` 的 prompt 构造器里。

### 4.4 Agent 列表有时不会直接进 tool description，而是进 system-reminder

源码路径：

- `src/tools/AgentTool/prompt.ts`
- `src/utils/attachments.ts`

Claude Code 为了避免 tool schema 经常变动导致缓存失效，引入了一个优化：

- `shouldInjectAgentListInMessages()`

当这个开关开启时：

- `AgentTool` 的 prompt 不再直接内嵌所有 agent 列表
- 只写一句：`Available agent types are listed in <system-reminder> messages in the conversation.`
- 实际 agent 列表改由 `agent_listing_delta` attachment 注入到对话里

附件内容包括：

- `addedTypes`
- `addedLines`
- `removedTypes`

而 `addedLines` 就来自 `formatAgentLine(agent)`，也就是：

- `agentType + whenToUse + tools`

这个设计很重要，因为它说明 Claude Code 的 Agent 使用说明可以进入两种载体：

1. Tool description
2. 对话中的 `<system-reminder>` 附件消息

这是 Claude Code 相比 Codex 更动态的一点。

### 4.5 如何进入具体 Agent 的系统提示词

源码路径：

- `src/tools/AgentTool/built-in/*.ts`
- `src/tools/AgentTool/loadAgentsDir.ts`
- `src/tools/AgentTool/runAgent.ts`
- `src/main.tsx`

### A. 内置 Agent

内置 Agent 通过 `getSystemPrompt()` 返回自己的系统提示词。

例如：

- `Explore`：强调 read-only、搜索策略、不能写文件
- `Plan`：强调 read-only、先探索后规划、输出 critical files

这些文本不只是“功能说明”，而是运行时硬约束。

### B. 自定义 Agent

自定义 markdown agent 的正文会变成 `systemPrompt`

`parseAgentFromMarkdown()` 中：

- `content.trim()` -> `systemPrompt`
- `getSystemPrompt()` 返回该正文

也就是说，Claude Code 的 agent 文件本质上是：

- frontmatter 负责“选择与配置”
- markdown body 负责“运行时系统提示词”

### C. 运行时如何用上

在 `runAgent.ts` 中，Claude Code 会构造 agent-specific options 和上下文，再按 `agentDefinition.getSystemPrompt()` 取到该 agent 的 system prompt。

在主线程非交互场景中，`main.tsx` 也会把选定 main-thread agent 的 `getSystemPrompt()` 直接用于系统提示词。

因此在 Claude Code 中：

- `whenToUse` 进主 Agent 的调用决策层
- `getSystemPrompt()` 进被调用 Agent 的执行层

### 4.6 MCP 在 Claude Code 里扮演什么角色

Claude Code 中，MCP 与 Agent 的关系比 Codex 更紧，但依然不是“把 Agent 说明写进 MCP”。

源码路径：

- `src/tools/AgentTool/loadAgentsDir.ts`
- `src/tools/AgentTool/runAgent.ts`
- `src/utils/attachments.ts`

主要有三种关系：

### A. `requiredMcpServers`

某些 Agent 需要某类 MCP server 才能显示或生效。

`filterAgentsByMcpRequirements()` 会根据当前可用 MCP server 过滤 Agent。

因此：

- MCP 会影响 Agent 是否进入可选列表
- 但不是 Agent 说明文本的存储位置

### B. `mcpServers` frontmatter

Agent frontmatter 可声明自己的 `mcpServers`

在 `runAgent.ts` 里：

- `initializeAgentMcpServers()` 会把这些 MCP server 连接起来
- 其工具会和 agent 原有 tools 合并

因此：

- Agent 可以带着自己的 MCP 依赖启动
- 这改变的是工具能力，不是主要的使用说明载体

### C. MCP 可用性会影响 `agent_listing_delta`

`attachments.ts` 里生成 agent listing delta 时，会先看当前 tool 池中有哪些 MCP server 真正有工具。

因此最终用户看到的 agent 列表，是“结合 MCP 可用性过滤后”的结果。

结论：

- Claude Code 的 MCP 主要影响 Agent 可见性和工具能力
- Agent 的说明文本主体仍在 `whenToUse + getSystemPrompt`

## 5. 对比总结

### 5.1 Codex 的思路

Codex 更偏“协议驱动”：

- `功能说明`：role description
- `使用说明`：spawn_agent tool description
- `运行时说明`：developer_instructions

对应载体：

- Function schema
- Function description
- developer_instructions

MCP 只是补充工具 namespace 描述，不是 Agent 说明中心。

### 5.2 Claude Code 的思路

Claude Code 更偏“定义对象驱动”：

- `功能说明`：`whenToUse`
- `运行时系统提示词`：`getSystemPrompt()`
- `动态可见性`：MCP requirements、permission、attachment delta

对应载体：

- AgentTool prompt/description
- system-reminder attachment
- agent-specific system prompt

MCP 会深度影响 Agent 可见性和工具能力，但不是主要说明文本的存储点。

## 6. 哪种方式更适合 Sirix

如果 Sirix 要做多 Agent，我建议直接吸收这两家的优点：

### 方案一：学 Codex

适合做平台底座时采用：

- 把“可选 agent 类型”和“使用规则”放进 Function Call schema
- 把 spawn 后的统一协作语义放进 developer/system instructions
- 把 agent role 做成配置层，而不是只做 prompt 模板

优点：

- 清楚
- 易控
- 适合严肃工程编排

### 方案二：学 Claude Code

适合做产品体验层时采用：

- `description/whenToUse` 单独作为“选型提示”
- `prompt/body` 单独作为“运行时系统提示词”
- 把可用 agent 列表做成动态附件，而不是每轮都塞进 tool schema
- MCP 负责 agent 可见性和能力门控

优点：

- 动态
- 适合 UI/会话态变化
- 更利于缓存优化

## 7. 最终结论

一句话总结：

- `Codex` 是把 Agent 说明主要注入到 `spawn_agent` 的 function schema 和 spawn 后的 `developer_instructions`
- `Claude Code` 是把 Agent 说明拆成 `whenToUse` 和 `getSystemPrompt()` 两层，前者进入 `AgentTool` 描述或 system-reminder，后者进入具体 Agent 的系统提示词

再简化一点：

- `Codex`：更像“工具协议驱动”
- `Claude Code`：更像“Agent 定义对象驱动”
