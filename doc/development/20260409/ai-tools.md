# AI工具实现要求

当前的App目前没有自己的AI agent工具, 帮我实现AI相关的工具, 要求如下

## 基础要求

实现一个类似Codex的工具的效果.

Codex的源代码可以参考:

/Volumes/MacData/Data/DownloadCode/codex

## 沙箱要求

像Codex一样要支持沙箱

## 启动要求

可以通过sirix唤起类似Codex的编程工具CLI效果.

不管是在哪个Terminal终端中启动的这个sirix, 它同时会在Desktop App和Mobile App的Terminal中展示这个CLI效果.

然后用户既可以在普通Terminal中使用sirix也可以在当前工程应用的Desktop App和Mobile App中的Terminal中使用这个sirix cli.

sirix cli支持多个实例.

sirix就是CLI的启动指令, 其它Terminal的Path的问题可以以后再处理, 不过Sirix应用中的Terminal需要支持直接通过调用sirix唤起CLI.

## 功能要求

要支持Codex一样的基础功能, 包括阅读文件, 修改文件, 执行Shell, 写Plan等内置工具, 这部分代码可以完全照抄.
MCP的支持和管理.
SKills的支持和管理.
要支持多Agent, 不同的Agent可以配置不同的模型, 配置不同的系统提示词, 配置支持的工具, 内置工具提供开关, 还可以添加其它MCP的工具.

## 设置要求

在Desktop App的右上角原形图标(应该是Avatar或者Account)点击后展示Context Menu, Menu上展示设置Item, 点击设置Item会跳转到设置页.
帮我实现设置页的功能, 并且保持UI风格和当前UI的一致性.

App仅做UI, 设置的核心能力有desktop-server完成.

这部分UI仅需要在Desktop App中实现, 移动端的App暂时不做.

设置页需要有如下设置:

### CLI设置

sirix cli的设置页.

可以配置全局的补充系统提示词.

### Provider和模型设置

可以在这里添加不同类型的模型, 比如OpenAI兼容模式的, Gemini的, Anthropic的, OpenAI Response的.

还可以增删改查Provider和模型.

一个Provider可以有多个模型.

模型可以配置最大上下文, 是否支持图片等.

这里要以功能来抽象出来, 以后可能会加更多Provider或者模型.

目前以上是文本模型, 后续会增加文生图, ASR, TTS等模型, 可以先预埋一些类型.

### SKills设置

全局设置.

可以增删改查SKills, 添加是选择一个文件夹导入.

提供是否开启的开关.

提供是否可以跨越沙盒访问其中的脚本的开关, 如果开启的话, 访问这个SKills中的文件和脚本等默认不受沙盒限制.

### MCP设置

全局设置.

可以增删改查MCP工具, JSON配置.

MCP默认不受沙盒限制.

提供精准控制的开关, 包括MCP总开关和分功能的开关.

### Agent设置

可以增删改查Agent.

可以配置每个Agent支持的MCP/SKills, 默认是全局配置的都可以用, 不过可以做更精细的控制, 比如把某个MCP/SKills关闭.

内置的SKills和MCP, 内置工具等也可以配置关闭.

可以配置Agent使用的模型.

可以配置Agent的系统提示词.

默认工具, SKills, MCP都是可以调用的, 但是可以针对其中的能力做更精细的控制, 比如某个能力需要授权才能运行.

## 注意事项

### 工作区

工作区也支持配置SKills, MCP等, 这和codex保持一致.

不过这些是在工程下的.sirix目录中配置, 并且兼容.codex目录中的配置, 优先使用.sirix, 没有内容的话使用.codex.

### 授权

默认都给授权.

某些用户配置需要独立授权的功能, 提供一次性授权, 这次会话都允许, 不允许等这些选项.



## 代码要求

实现要优雅, 能抽象出来的抽象出来.

保证功能稳定性, 健壮性, 安全性.

关键位置需要写注释.


---
请先研究一下如何实现整体功能, 给出Plan文档, 并且如果有不确定的地方, 请指出, 我会解答你的疑问后你再执行.
plan写到doc/plan/下







## 问题回答

1, 需要
2, 需要可以交互输入
3, 允许单机运行, 不过要提示没有登录, 弹出是否登录的选项, 默认确定, 如果用户点击取消依然可以使用
4, 使用`~/.sirix/config.toml`, 旧的也迁移到`~/.sirix/`
5, 文件级 fallback即可
6, 秘钥配置写到~/.sirix/
7, 是

## 问题回答落地解释（2026-04-09）

基于以上 7 条回答，实施时按以下约束执行：

1. `sirix` 在 `desktop-server` 未运行时，需要支持自动拉起。
2. Mobile App 对外部 Terminal 启动的 `sirix` 会话，必须支持交互输入，不仅是只读展示。
3. 未登录状态允许本机单机运行；但首次进入要弹出“是否登录”提示，默认确认，取消后继续可用。
4. 全局主配置路径固定为 `~/.sirix/config.toml`，并将历史配置迁移到 `~/.sirix/` 目录体系。
5. 工作区兼容规则采用文件级 fallback：优先 `.sirix`，缺失时回退 `.codex`。
6. Provider 密钥第一阶段存储在 `~/.sirix/` 下（由 `desktop-server` 统一管理读写）。
7. 授权粒度按全量能力设计：内置工具级、MCP server 级、MCP tool 级、Skill 级、Shell 命令级都支持。

## 当前执行进度说明（2026-04-09 已完成）

以下能力已完成并可用：

- `desktop-server` 已新增 AI 配置与会话基础模块，并提供 `/ai/config`、`/ai/sessions` 本地接口。
- `sirix` CLI 已有可运行版本，支持自动拉起 `desktop-server`、会话创建/恢复与交互输入输出。
- 配置主路径已切换到 `~/.sirix/config.toml`，并有旧 `~/.codex` 迁移逻辑。
- 工作区已支持 `.sirix` 优先、`.codex` 回退的文件级 fallback。
- backend 已新增独立 `ai_sessions` 相关数据表与本地创建接口，AI session 与 terminal session 已独立建模并通过关联映射展示。
- Desktop App 已支持右上角 Avatar 菜单（Settings / Logout）和 AI Settings 页面，支持 CLI / Provider / Skills / MCP / Agent 的可视化编辑与保存。
- MCP 已支持总开关与分功能开关（stdio/http），并支持 server 级工具白名单/黑名单字段。
- MCP 配置保存前会做 transport 推断与结构校验，拒绝无效 JSON/TOML、无 transport、缺少 `command/url`、工具白名单黑名单冲突等错误配置。
- Skills 已支持“导入文件夹”交互入口，并在导入和保存时校验目录存在且包含 `SKILL.md`。
- 会话级授权已支持 `once / session / deny` 的检查与决策接口、实时审批弹窗、本地持久化缓存，以及镜像到 backend 审计表。
- Agent 设置页已支持结构化 Capability Rules 编辑，不再依赖自由文本 `key:mode` 手工输入。

## Codex 迁移说明

从 Codex 迁移/借鉴到 Sirix 的可靠性、稳定性、安全性、健壮性逻辑，已整理到：

- `doc/development/20260409/codex-migration-notes.md`
