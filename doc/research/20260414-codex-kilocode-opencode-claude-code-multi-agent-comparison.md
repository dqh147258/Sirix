# Codex、Kilo Code、OpenCode、Claude Code 多 Agent 实现对比研究

## 1. 研究范围与说明

本文基于当前本地源码快照做对比，不基于官网宣传页做结论。

研究对象：

- Codex 源码：`/Volumes/MacData/Data/DownloadCode/codex`
- Kilo Code 源码：`/Volumes/MacData/Data/DownloadCode/kilocode`
- OpenCode 源码：`/Volumes/Code/DownloadCode/AI/opencode`
- Claude Code 源码：`/Volumes/Code/DownloadCode/AI/claude-code`

本文讨论的“多 Agent”重点不是“是否能创建第二个会话”，而是以下五个能力：

1. 是否有明确的 Agent 角色抽象
2. 是否有可编程的 Agent 生命周期管理
3. Agent 之间是否能持续通信与并发协作
4. 上下文是“完整继承、摘要回传”还是“强隔离”
5. 是否便于扩展、限制、观测和工程化落地

## 2. 关键源码入口

### 2.1 Codex

- `codex-rs/core/src/tools/spec.rs`
- `codex-rs/tools/src/agent_tool.rs`
- `codex-rs/core/src/tools/handlers/multi_agents_v2/spawn.rs`
- `codex-rs/core/src/tools/handlers/multi_agents_v2/message_tool.rs`
- `codex-rs/core/src/tools/handlers/multi_agents_v2/wait.rs`
- `codex-rs/core/src/agent/role.rs`
- `codex-rs/core/src/config/agent_roles.rs`

### 2.2 OpenCode

- `packages/opencode/src/agent/agent.ts`
- `packages/opencode/src/tool/task.ts`
- `packages/opencode/src/tool/task.txt`
- `packages/web/src/content/docs/agents.mdx`
- `packages/opencode/test/permission-task.test.ts`

### 2.3 Kilo Code

- `src/core/tools/newTaskTool.ts`
- `src/core/task/Task.ts`
- `src/shared/modes.ts`
- `apps/kilocode-docs/docs/basic-usage/orchestrator-mode.md`
- `apps/kilocode-docs/docs/basic-usage/using-modes.md`
- `apps/kilocode-docs/static/downloads/boomerang-tasks/kilocodemodes.json`

### 2.4 Claude Code

- `src/tools/AgentTool/AgentTool.tsx`
- `src/tools/AgentTool/runAgent.ts`
- `src/tools/AgentTool/builtInAgents.ts`
- `src/tools/AgentTool/built-in/generalPurposeAgent.ts`
- `src/coordinator/coordinatorMode.ts`
- `src/tools/TeamCreateTool/TeamCreateTool.ts`
- `src/tools/SendMessageTool/SendMessageTool.ts`
- `src/tools/TaskCreateTool/TaskCreateTool.ts`

## 3. 四个项目的核心区别

### 3.1 Codex：显式 Agent 控制 API，最像“可编排的多 Agent 平台”

Codex 的多 Agent 不是“顺手开个子任务”，而是一套明确的协作协议。

它的特点：

- 有明确工具面：`spawn_agent`、`wait_agent`、`close_agent`、`list_agents`、`send_message`、`followup_task`
- 有明确角色面：`default`、`explorer`、`worker`，并允许用户通过 agent role 配置继续扩展
- 有明确生命周期面：spawn、queued message、trigger turn、wait mailbox update、close
- 有 v1 / v2 两套协作协议，v2 明显更强调 task path、mailbox 和非阻塞协作
- Agent role 不是简单 prompt 字符串，而是配置层，可叠加到现有 session config 上

本质上，Codex 的多 Agent 是“主 Agent 作为调度者，子 Agent 作为一等运行实体”，偏平台化、协议化。

### 3.2 OpenCode：以 session child + task tool 为核心，轻量但很实用

OpenCode 的多 Agent 更偏“会话树 + 子代理工具”。

它的特点：

- 内置 primary agent 和 subagent 两类
- 通过 `task` 工具把任务发送给某个 `subagent_type`
- 子 Agent 会创建 child session，可以通过 `task_id` 继续复用上下文
- 子 Agent 权限继承后再收紧，例如 `general` 禁用 todo，`explore` 是只读探索
- 对 subagent 的可见性、权限和调用范围有清晰配置，例如 `permission.task`

本质上，OpenCode 的多 Agent 是“主会话调用子会话”，比 Codex 轻一些，但结构已经比较完整。

### 3.3 Kilo Code：本质是子任务编排，不是强实时协作型多 Agent

Kilo Code 的多 Agent 更准确说是“Orchestrator Mode + subtask delegation”。

它的特点：

- 通过 `new_task` 在指定 mode 下创建子任务
- 父任务在创建子任务后会 `isPaused = true`，进入等待
- 子任务完成后，父任务通过摘要结果恢复
- 上下文传递方式非常明确：向下靠 `message`，向上靠 `attempt_completion.result`
- 文档明确强调子任务是隔离上下文，而不是自动继承父任务上下文

这意味着它更像“任务树调度器”，而不是“多个活跃 Agent 持续互发消息、并行推进”的体系。

### 3.4 Claude Code：最重工程化，既有 subagent，也有 coordinator/swarm/team

Claude Code 的多 Agent 明显分成两层：

- 常规层：`AgentTool` 拉起 subagent，支持 background、worktree isolation、remote
- 编排层：`coordinatorMode` + `TeamCreateTool` + `SendMessageTool` + task list + mailbox

它的特点：

- 不仅能起子 Agent，还能起 team / swarm
- 支持 worker 持续异步执行，结果通过 `<task-notification>` 回流
- 有 coordinator system prompt，明确规定研究、综合、实现、验证的分工
- 支持更强的隔离模式，如 `worktree`
- 有更重的产品化机制，如 feature gate、后台 agent、remote bridge、mailbox

本质上，Claude Code 不是简单“多 Agent”，而是“多 Agent + 协调者模式 + 团队协作基础设施”。

## 4. 逐项对比

| 维度 | Codex | OpenCode | Kilo Code | Claude Code |
| --- | --- | --- | --- | --- |
| 核心抽象 | Agent + Role + Mailbox + Tool API | Primary/Subagent + Child Session | Mode + Subtask | Agent + Worker + Team + Coordinator |
| 创建方式 | `spawn_agent` | `task(subagent_type=...)` | `new_task(mode=...)` | `AgentTool` / `TeamCreateTool` |
| 持续通信 | 强，支持 `send_message` / `followup_task` | 中，主要通过继续 task session | 弱，主要靠子任务完成后摘要回传 | 很强，支持 worker 续跑、team mailbox、send message |
| 生命周期控制 | 很完整 | 中等 | 偏弱 | 很完整 |
| 并发能力 | 强 | 中上 | 中下 | 很强 |
| 上下文模型 | 可 fork，可控深度，可复用 agent | 子 session，可通过 `task_id` 延续 | 子任务隔离，摘要回传 | 可 fork，可 background，可 worktree/remote |
| 角色系统 | 强，role 是配置层 | 强，agent 可 JSON/Markdown 配置 | 中，主要是 mode | 很强，built-in agent + coordinator worker + swarm |
| 安全/权限 | 强，工具级、生命周期级 | 强，permission/task/tool 都可控 | 中，更多是 mode/tool 分组限制 | 强，权限、隔离、leader/worker 桥接都很多 |
| 工程复杂任务适配度 | 很强 | 强 | 中 | 很强 |

## 5. 每个项目的优缺点

### 5.1 Codex

#### 优点

- 多 Agent 是显式协议，不是隐式魔法，生命周期非常清楚
- `spawn_agent`、`send_message`、`followup_task`、`wait_agent`、`close_agent` 组合很完整
- role 体系很强，内置 `explorer`、`worker`，并允许用户通过配置扩展
- v2 方案已经从“单纯子会话”升级为“带 mailbox 更新的协作树”
- 适合把多 Agent 当平台能力继续往上封装

#### 缺点

- 架构复杂度高，接入和维护成本明显高于其它三个项目
- 概念层较多，包含 role、spawn depth、session source、mailbox、tool protocol 等
- 对实现者要求高，更适合工程团队，不适合轻量级快速改造

#### 结论

Codex 的优势不是“能起几个 Agent”，而是“把多 Agent 做成一套可编程运行时”。

### 5.2 OpenCode

#### 优点

- 设计简洁，理解成本低
- session tree + subagent 模型直观，容易落地
- primary / subagent / hidden system agent 分层清楚
- agent 可以通过 JSON 或 Markdown 配置，扩展性很好
- `permission.task` 让“谁能调用谁”这件事可配置

#### 缺点

- 生命周期控制弱于 Codex 和 Claude Code，没有那么强的 agent runtime 感
- 协作更多停留在“父会话调用子会话”，而不是更丰富的 mailbox / team 协作
- 并发和团队级调度能力有，但没有形成更完整的 orchestration 基础设施

#### 结论

OpenCode 的路线是“够用、清楚、好配置”，非常适合中等复杂度的多 Agent CLI。

### 5.3 Kilo Code

#### 优点

- Orchestrator Mode 非常容易理解，适合用户直接上手
- 子任务边界清晰，向下传 message、向上传 summary，心智模型简单
- mode 体系和 VS Code 交互结合得比较自然
- 对复杂任务拆分有帮助，适合作为流程编排入口

#### 缺点

- 本质更像“暂停父任务，执行子任务，再恢复父任务”，不是强实时多 Agent 协作
- 父子之间的状态交换主要靠最终摘要，信息带宽偏低
- 没有形成 Codex/Claude Code 那种完整的 agent mailbox、agent list、agent close、team message 体系
- 并发协作能力弱，更多是串行树状编排

#### 结论

Kilo Code 的强项是“任务拆解工作流”，不是“多活 Agent 协同系统”。

### 5.4 Claude Code

#### 优点

- 多 Agent 能力覆盖面最广，包含 subagent、background worker、team、swarm、mailbox
- coordinator 模式非常工程化，明确要求并行研究、综合、实现、验证
- 支持 `worktree` 隔离，这对并行改代码很关键
- 有 `SendMessageTool`、`TeamCreateTool`、task list 等更高层协作构件
- 产品化程度高，适合复杂工程任务持续运行

#### 缺点

- 体系很重，很多能力依赖 feature gate、环境变量、内部运行约束
- 概念和实现非常多，理解和裁剪成本高
- 某些能力明显服务于 Claude Code 自身产品形态，不一定适合直接照搬

#### 结论

Claude Code 是“工程协作型多 Agent 系统”，不是单纯的 subagent 功能。

## 6. 评分

### 6.1 评分维度

采用 10 分制，按以下维度综合判断：

- 架构完整度：25%
- 并发协作能力：25%
- 隔离与安全能力：20%
- 可配置与扩展性：15%
- 可运维与工程实用性：15%

说明：

- 分数是基于当前源码结构的工程判断，不代表产品市场表现
- 分数偏向“做复杂研发任务时的系统能力”，不是“学习成本最低”

### 6.2 评分表

| 项目 | 架构完整度 | 并发协作 | 隔离与安全 | 配置扩展 | 工程实用性 | 总分 |
| --- | --- | --- | --- | --- | --- | --- |
| Codex | 9.5 | 9.3 | 8.8 | 9.2 | 9.1 | 9.2 |
| Claude Code | 9.3 | 9.6 | 8.9 | 8.5 | 9.2 | 9.1 |
| OpenCode | 8.1 | 7.8 | 8.0 | 9.0 | 7.9 | 8.1 |
| Kilo Code | 6.8 | 6.1 | 7.2 | 8.0 | 6.6 | 6.9 |

### 6.3 排名解释

#### 第 1 名：Codex，9.2

原因：

- 多 Agent 能力最“平台化”
- 角色、生命周期、消息、等待、关闭都做成了显式协议
- 非常适合继续演化成 Sirix 自己的多 Agent 基础设施

#### 第 2 名：Claude Code，9.1

原因：

- 协作能力甚至比 Codex 更激进，尤其是 coordinator/swarm/team 这一层
- 但它明显更重产品化、更多 feature gate、更多内部假设
- 适合借鉴“协作形态”，不适合原样照搬全部实现

#### 第 3 名：OpenCode，8.1

原因：

- 在复杂度和能力之间平衡得很好
- 已经具备较成熟的 subagent/session tree/configuration 体系
- 但距离“完整 Agent runtime”还有一段距离

#### 第 4 名：Kilo Code，6.9

原因：

- 它更像“子任务编排系统”
- 任务拆分体验不错，但多 Agent 协作深度不够
- 适合流程拆解，不适合高并发协同编码

## 7. 最终结论

如果只看“多 Agent 架构成熟度”：

1. Codex
2. Claude Code
3. OpenCode
4. Kilo Code

如果只看“最适合直接借鉴到 Sirix 的实现思路”：

1. Codex 的显式 Agent 生命周期与 role 体系
2. Claude Code 的 coordinator 并发协作方法
3. OpenCode 的轻量配置化 subagent 体系
4. Kilo Code 的 Orchestrator 任务拆解交互

一句话总结：

- Codex 最像“多 Agent 平台底座”
- Claude Code 最像“工程团队协作系统”
- OpenCode 最像“轻量但成熟的 subagent CLI”
- Kilo Code 最像“任务树式 Orchestrator”
