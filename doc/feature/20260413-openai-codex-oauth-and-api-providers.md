# OpenAI Codex OAuth / API Providers

## 本次功能

本次提交为 Sirix 增加两种新的 OpenAI Provider：

- `OpenAI Codex OAuth`
  - 支持在 Desktop App 中发起浏览器授权
  - 支持导入 Codex 风格的 `auth.json`
  - 支持同一份 Sirix 配置中存在多个独立的 Codex OAuth Provider
- `OpenAI Codex API`
  - 支持配置 `Base URL`
  - 支持配置 `API Key Env Var`
  - 支持配置内联 `API Key`

同时，这两类 Provider 的模型都可以进入 Sirix 的 Provider / Model 配置链路，并在 Sirix session 中被 `/model` 选择器使用。

## 代码位置

### 1. Desktop Server Provider / Auth 实现

- `desktop-server/src/app/ai/openai_auth.rs`
  - 新增 provider 级 OpenAI auth 管理模块
  - 为每个 OAuth provider 单独维护 auth home
  - 支持浏览器登录、JSON 导入、登出、状态读取
- `desktop-server/src/app/ai/config.rs`
  - 为 provider 增加 `open_ai_codex_oauth` / `open_ai_codex_api` 类型
  - 新增 provider 级 OpenAI auth 存储路径辅助方法
- `desktop-server/src/app/state.rs`
  - 在全局状态中挂载 `OpenAiAuthRegistry`
- `desktop-server/src/api/ai.rs`
  - 增加 OpenAI auth 相关本地 API
  - 增加 OAuth provider 的模型发现逻辑
  - 增加 OAuth provider 的响应请求头与 token 刷新逻辑
- `desktop-server/src/api/mod.rs`
  - 注册 `/ai/providers/:provider_id/openai-auth/*` 路由

### 2. Flutter Desktop 设置页

- `client/packages/infra_api/lib/src/ai_models.dart`
  - 增加新的 Provider kind
  - 增加 OpenAI auth 状态 DTO
- `client/packages/infra_api/lib/src/desktop_local_client.dart`
  - 增加 OpenAI auth 状态、登录、导入、登出接口
- `client/packages/feature_settings_ai/lib/src/ai_settings_state.dart`
  - 增加 provider 级 OpenAI auth 状态与忙碌态
- `client/packages/feature_settings_ai/lib/src/ai_settings_view_model.dart`
  - 增加 OpenAI auth 状态加载、浏览器登录轮询、JSON 导入、登出逻辑
- `client/packages/feature_settings_ai/lib/src/sections/provider_settings_section.dart`
  - 增加 `OpenAI Codex OAuth` / `OpenAI Codex API` preset
  - 为 OAuth provider 增加 auth 面板、浏览器登录、JSON 导入、登出按钮
  - 为 JSON 导入补充文件拖拽区、手动路径读取和粘贴导入入口
  - 将 `Load From File` 切到 `file_picker`，并使用路径输入框推导 `initialDirectory`，让隐藏目录如 `~/.codex` 也能直接作为打开位置
  - 不依赖原生扩展名过滤，改为允许选择任意文件后再由 Sirix 自己校验 JSON，避免桌面端 picker 把 `auth.json` 置为不可选
  - 为 OAuth provider 调整表单字段展示逻辑

## 实现方法

### 1. 多 Provider OAuth 方法

Sirix 没有沿用 Codex CLI “只有一个全局 OAuth 登录态”的方式，而是按 `provider_id` 拆分：

- 每个 OAuth provider 都有自己独立的 auth home
- 浏览器登录与 JSON 导入都写入 provider 级 auth home
- 状态读取、登出、请求发起都只读取当前 provider 对应的 auth

这样可以在 Sirix 中同时存在多个 Codex OAuth Provider，而不会互相覆盖状态。

### 2. OAuth 登录与导入方法

OAuth provider 支持两种认证入口：

- 浏览器授权
  - Desktop App 调用 `desktop-server` 登录接口
  - `desktop-server` 启动本地回调服务并返回 `auth_url`
  - Desktop App 打开系统浏览器后轮询 provider 级 auth 状态
- JSON 导入
  - 直接导入 Codex 风格 `auth.json`
  - 支持 `file_picker` 文件选择器、文件拖拽、本地路径读取和直接粘贴 JSON
  - 文件选择器会优先使用当前路径输入框的父目录作为初始目录，便于直接打开隐藏目录
  - `desktop-server` 校验 JSON 中的 ChatGPT token 结构
  - 校验通过后写入 provider 级 auth 存储

### 3. 模型发现方法

- `OpenAI Codex OAuth`
  - 优先尝试调用 ChatGPT Codex backend 的 `/models`
  - 请求头带 `Authorization` 和 `chatgpt-account-id`
  - 失败时不阻塞配置保存，直接返回空模型列表
- `OpenAI Codex API`
  - 按 OpenAI 风格 `/models` 方式尝试拉取
  - 失败时直接返回空模型列表
  - 用户仍可手工添加模型

### 4. 运行时接入方法

Sirix 运行时仍然保持原有架构：

- runtime 继续只连本地 `sirix-session-proxy`
- 本地代理根据 `model` 解析真实 provider
- `OpenAI Codex OAuth` 请求会附带 provider 级 OAuth token 与 `chatgpt-account-id`
- `OpenAI Codex API` 继续按普通 API key provider 发请求

这样不会破坏 Sirix 已有的 session 级多 provider 路由设计。

## 当前结论

本次变更后，Sirix 已经具备：

- 多个独立 `Codex OAuth` Provider 并存
- Desktop App 内直接发起浏览器登录
- 导入 Codex `auth.json`
- 将 `Codex OAuth` 和 `Codex API` 的模型接入 Sirix 的 Provider / Model 配置与 session 运行链路

如果远端模型发现失败，Sirix 会退回“空模型列表 + 用户手工添加模型”的保守行为，不会因为上游接口不稳定而阻断 Provider 的实际使用。
