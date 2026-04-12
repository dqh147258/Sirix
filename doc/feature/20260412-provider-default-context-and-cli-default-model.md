# Provider 默认上下文与 CLI 默认模型

## 本次功能

本次提交完成 AI 设置页中与 Provider / Model 相关的三个能力补齐：

- Provider 现在可以配置默认的模型上下文长度
- Model 的上下文长度现在可以留空，留空时会回退到 Provider 默认值
- Provider / Model 设置页现在可以直接设置 Sirix CLI 的默认模型
- Provider 的 Base URL 末尾带 `/` 的情况已确认兼容，并补充回归测试

## 代码位置

### 1. 后端配置与运行时默认解析

- `desktop-server/src/app/ai/config.rs`
  - `ProviderConfig` 增加 `default_context_window`
  - `ModelConfig.context_window` 改为可选
  - 增加统一的上下文长度生效解析逻辑
  - 默认启动时优先解析 `default-agent`，使 Provider / Model 页设置的默认模型能够直接作用到 Sirix CLI
  - Bridge models 输出 `is_default`，让 runtime picker 与当前默认模型保持一致

### 2. Provider 模型发现与 API 兼容

- `desktop-server/src/api/ai.rs`
  - `/models` 聚合输出使用统一的生效上下文长度
  - Provider 模型发现时，如果上游没返回上下文长度，则优先回退到 Provider 默认值
  - 补充 Base URL 末尾 `/` 的兼容回归测试

### 3. Flutter 设置页与配置模型

- `client/packages/infra_api/lib/src/ai_models.dart`
  - Provider 默认上下文长度改为可序列化字段
  - Model 上下文长度改为可空字段
- `client/packages/feature_settings_ai/lib/src/ai_settings_view_model.dart`
  - 增加默认模型与 Provider 默认上下文的状态维护
  - 通过收敛到 `default-agent` 保持默认模型与 Sirix CLI 启动链路一致
- `client/packages/feature_settings_ai/lib/src/sections/provider_settings_section.dart`
  - Provider 卡片增加默认上下文编辑入口
  - Model 编辑弹窗支持上下文长度留空
  - 模型列表增加“设为 CLI 默认模型”的交互与状态展示

## 实现方法

### 1. 上下文长度生效顺序

上下文长度统一按下面顺序解析：

1. Model 显式配置的 `context_window`
2. Provider 的 `default_context_window`
3. Sirix 按 Provider 类型给出的供应商默认兜底值

这样做的目的是同时满足“模型可细配”和“Provider 级统一默认值”两种使用方式，并让设置页显示、模型发现结果与运行时输出保持一致。

### 2. 默认模型落点

Sirix 当前默认启动链路本质上仍然依赖 agent 配置，因此没有额外引入第二套“默认模型”持久化字段，而是把 Provider / Model 页上的默认模型收敛到 `default-agent`：

- 设置页点击默认模型时，会同步更新 `default-agent` 的 `provider_id` / `model_id`
- 启动 Sirix CLI 且未显式指定 agent 时，优先解析 `default-agent`
- runtime bridge 输出的模型 catalog 会把当前默认模型标记成 `is_default`

这样可以最小改动现有启动链路，同时保证设置页行为、Sirix CLI 默认启动行为和运行时模型选择器一致。

### 3. Base URL 兼容确认

Provider Base URL 原有归一化逻辑已经兼容末尾是否带 `/` 的情况，本次未额外改动请求拼接逻辑，只通过测试把该行为固定下来，避免后续回归。
