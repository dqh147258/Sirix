# Code Review — 2026-04-11 未提交变更

## 变更概览

| 模块 | 变更 |
|------|------|
| Flutter Client | Terminal 管理从 View 下沉到 ViewModel，xterm 改为本地 vendored |
| Desktop Server | AI session 支持复用当前终端 + Legacy Codex 配置兼容层 |
| Docs | AGENTS.md 新增日志约定 |
| 格式化 | 大量 Rust 代码 rustfmt 重排 |

## 🔴 必须修复

### #1 terminal_view_model.dart — Terminal 缓存无 dispose

`_terminalCache` 中的 `Terminal` 对象在 `_pruneTerminalCache` 移除后没有被 dispose，ViewModel 的 `dispose()` 也没有清理缓存。xterm 的 `Terminal` 内部有 buffer、监听器等资源，会造成内存泄漏。

```dart
// terminal_view_model.dart — dispose() 中缺少缓存清理
void dispose() {
    unawaited(_detachChannel());
    unawaited(_sessionChannelSubscription?.cancel());
    super.dispose();  // ← _terminalCache 没有清理
}
```

**建议：** 在 `dispose()` 和 `_pruneTerminalCache` 中对被移除的 Terminal 调用清理。

### #2 terminal_view_model.dart — `_handleTerminalClosed` 丢失了关闭通知

移除了 `[terminal closed]` 的终端输出，用户在终端里看不到关闭提示。

```dart
// 之前有：
// _events.add(TerminalUiEvent.output(
//   terminalId: terminalId,
//   text: '\r\n[terminal closed]\r\n',
// ));
```

**建议：** 如果是有意移除，在 commit message 中说明；否则恢复该提示。

### #5 config.rs — legacy 配置检测过于宽松

`looks_like_legacy_codex_config` 只要匹配到任意 1 个 key（如 `model`）就会尝试 legacy 解析。`mcp_servers` 是新旧格式都有的字段，容易误判。

```rust
fn looks_like_legacy_codex_config(table: &toml::map::Map<String, TomlValue>) -> bool {
    ["model", "model_provider", "model_providers", "profiles", "mcp_servers",
     "preferred_auth_method", "sandbox_workspace_write", "web_search", "disable_response_storage"]
    .iter().any(|key| table.contains_key(*key))
}
```

**建议：** 增加更多判据（如必须同时有 2+ 个 legacy 特征字段），或优先检查 Sirix 格式特征字段（如 `[agents]`、`[providers]` 的特定结构），有则直接走新解析。

## 🟡 建议修复

### #3 session.rs — `insert` 持有两个 write lock 的风险

```rust
pub async fn insert(&self, record: AiSessionRecord) {
    let mut sessions = self.sessions.write().await;
    let mut terminal_index = self.terminal_index.write().await;
    // ...
}
```

同时持有 `sessions` 和 `terminal_index` 两个 `RwLock` 的 write lock，如果其他代码以相反顺序获取这两个锁，会产生死锁。目前只有 `insert` 同时拿两把锁，短期内不会死锁，但未来维护者可能踩坑。

**建议：** 合并为单个 `RwLock<(HashMap, HashMap)>` 或在文档中注明锁顺序约定。

### #4 sirix.rs — `run_codex_in_current_terminal` 使用 `exec()` 无预检

```rust
#[cfg(unix)]
{
    use std::os::unix::process::CommandExt;
    let error = command.exec();
    return Err(error).context("failed to exec codex in current terminal");
}
```

`exec()` 会替换当前进程，如果 codex 可执行文件不存在，用户只会看到模糊的错误信息。

**建议：** exec 前检查 `codex_executable` 是否存在且可执行，给出更明确的错误提示。

### #7 terminal_view_model.dart — `TerminalPageConfig` 移除了 `accessToken` 比较但需确认一致性

`==` 和 `hashCode` 中移除了 `accessToken`，但需确认构造函数和 Provider key 是否还在使用它。如果还在用但比较时忽略了，可能导致 cache miss 或者不同的 config 被认为相同。

### #8 sirix.rs — `CurrentTerminalLaunch` 结构体重复定义

`CurrentTerminalLaunch` 在 `session.rs` 和 `sirix.rs` 中各定义了一份几乎相同的结构体。

**建议：** 放到共享位置（如 `ai` module 的公共类型中）。

## 🟢 做得好的地方

- ✅ Terminal 管理从 View 下沉到 ViewModel，符合 MVVM 架构
- ✅ 移除了 `TerminalUiEvent` 的 Stream 中间层，减少事件传递复杂度
- ✅ Legacy Codex 配置兼容层有单元测试覆盖
- ✅ `AiSessionRegistry.insert` 正确处理了终端复用时旧 session 的清理
- ✅ 新增环境变量 `SIRIX_TERMINAL_SESSION_ID` 和 `SIRIX_CODEX_EXECUTABLE` 传递方式清晰
