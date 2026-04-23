use std::{env, fs, path::Path, process::Command, sync::OnceLock};

use anyhow::Context;

/// 终端 tmux 优先策略的环境变量开关：
/// - true/1/yes/on  => 优先尝试 tmux
/// - false/0/no/off => 强制走旧实现
pub const PREFER_TMUX_ENV: &str = "SIRIX_PREFER_TMUX_TERMINAL";

const ANSI_YELLOW: &str = "\u{1b}[33m";
const ANSI_RESET: &str = "\u{1b}[0m";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalLaunchStrategyKind {
    LegacyShell,
    TmuxShell,
}

impl TerminalLaunchStrategyKind {
    pub const fn as_api_str(self) -> &'static str {
        match self {
            Self::LegacyShell => "legacy_shell",
            Self::TmuxShell => "tmux_shell",
        }
    }
}

#[derive(Debug, Clone)]
pub struct TerminalLaunchWarning {
    pub code: &'static str,
    pub message: String,
    pub install_commands: Vec<String>,
}

impl TerminalLaunchWarning {
    /// 统一的黄色告警渲染，CLI 侧直接输出这些行即可。
    pub fn to_colored_lines(&self, prefix: &str) -> Vec<String> {
        let mut lines = vec![format!(
            "{ANSI_YELLOW}[{prefix}] {}{ANSI_RESET}",
            self.message
        )];
        if !self.install_commands.is_empty() {
            lines.push(format!(
                "{ANSI_YELLOW}[{prefix}] 安装 tmux 建议命令：{ANSI_RESET}"
            ));
            for command in &self.install_commands {
                lines.push(format!("{ANSI_YELLOW}  {command}{ANSI_RESET}"));
            }
        }
        lines
    }
}

#[derive(Debug, Clone)]
pub struct TerminalCommandPlan {
    pub program: String,
    pub args: Vec<String>,
    pub strategy: TerminalLaunchStrategyKind,
    pub display_shell: String,
    pub tmux_session_name: Option<String>,
}

#[derive(Debug, Clone)]
pub struct TerminalLaunchSelection {
    pub primary: TerminalCommandPlan,
    pub fallback: Option<TerminalCommandPlan>,
    pub warnings: Vec<TerminalLaunchWarning>,
}

#[derive(Debug, Clone)]
pub struct TerminalLaunchRequest<'a> {
    pub requested_shell: &'a str,
    pub cwd: Option<&'a Path>,
    pub prefer_tmux: bool,
    pub tmux_session_seed: &'a str,
}

pub trait TerminalLauncher {
    fn kind(&self) -> TerminalLaunchStrategyKind;
    fn build_plan(&self, request: &TerminalLaunchRequest<'_>) -> TerminalCommandPlan;
}

#[derive(Debug, Default, Clone, Copy)]
pub struct LegacyShellLauncher;

impl TerminalLauncher for LegacyShellLauncher {
    fn kind(&self) -> TerminalLaunchStrategyKind {
        TerminalLaunchStrategyKind::LegacyShell
    }

    fn build_plan(&self, request: &TerminalLaunchRequest<'_>) -> TerminalCommandPlan {
        TerminalCommandPlan {
            program: request.requested_shell.to_string(),
            args: Vec::new(),
            strategy: self.kind(),
            display_shell: request.requested_shell.to_string(),
            tmux_session_name: None,
        }
    }
}

#[derive(Debug, Default, Clone, Copy)]
pub struct TmuxShellLauncher;

impl TerminalLauncher for TmuxShellLauncher {
    fn kind(&self) -> TerminalLaunchStrategyKind {
        TerminalLaunchStrategyKind::TmuxShell
    }

    fn build_plan(&self, request: &TerminalLaunchRequest<'_>) -> TerminalCommandPlan {
        let session_name = sanitize_tmux_session_seed(request.tmux_session_seed);
        let mut args = vec![
            "-u".to_string(),
            "new-session".to_string(),
            "-A".to_string(),
            "-s".to_string(),
            session_name.clone(),
        ];
        if let Some(cwd) = request.cwd {
            args.push("-c".to_string());
            args.push(cwd.display().to_string());
        }
        args.push(request.requested_shell.to_string());
        TerminalCommandPlan {
            program: "tmux".to_string(),
            args,
            strategy: self.kind(),
            display_shell: format!("tmux({})", request.requested_shell),
            tmux_session_name: Some(session_name),
        }
    }
}

#[derive(Debug, Clone)]
pub struct TmuxAvailability {
    pub available: bool,
    pub detail: String,
}

pub struct TerminalLaunchResolver<L, T>
where
    L: TerminalLauncher,
    T: TerminalLauncher,
{
    legacy: L,
    tmux: T,
}

impl Default for TerminalLaunchResolver<LegacyShellLauncher, TmuxShellLauncher> {
    fn default() -> Self {
        Self {
            legacy: LegacyShellLauncher,
            tmux: TmuxShellLauncher,
        }
    }
}

impl<L, T> TerminalLaunchResolver<L, T>
where
    L: TerminalLauncher,
    T: TerminalLauncher,
{
    pub fn resolve(
        &self,
        request: &TerminalLaunchRequest<'_>,
        tmux_probe: &TmuxAvailability,
    ) -> TerminalLaunchSelection {
        let legacy_plan = self.legacy.build_plan(request);

        if cfg!(windows) || !request.prefer_tmux {
            return TerminalLaunchSelection {
                primary: legacy_plan,
                fallback: None,
                warnings: Vec::new(),
            };
        }

        if !tmux_probe.available {
            return TerminalLaunchSelection {
                primary: legacy_plan,
                fallback: None,
                warnings: vec![build_tmux_missing_warning()],
            };
        }

        TerminalLaunchSelection {
            primary: self.tmux.build_plan(request),
            fallback: Some(legacy_plan),
            warnings: Vec::new(),
        }
    }
}

pub fn select_terminal_launch(request: &TerminalLaunchRequest<'_>) -> TerminalLaunchSelection {
    TerminalLaunchResolver::default().resolve(request, cached_tmux_availability())
}

pub fn cached_tmux_availability() -> &'static TmuxAvailability {
    static TMUX_AVAILABILITY: OnceLock<TmuxAvailability> = OnceLock::new();
    TMUX_AVAILABILITY.get_or_init(detect_tmux_availability)
}

pub fn detect_tmux_availability() -> TmuxAvailability {
    if cfg!(windows) {
        return TmuxAvailability {
            available: false,
            detail: "windows does not use tmux launcher".to_string(),
        };
    }

    match Command::new("tmux").arg("-V").output() {
        Ok(output) if output.status.success() => {
            let version = String::from_utf8_lossy(&output.stdout).trim().to_string();
            TmuxAvailability {
                available: true,
                detail: if version.is_empty() {
                    "tmux detected".to_string()
                } else {
                    version
                },
            }
        }
        Ok(output) => TmuxAvailability {
            available: false,
            detail: format!("tmux probe exited with status {}", output.status),
        },
        Err(error) => TmuxAvailability {
            available: false,
            detail: format!("tmux probe failed: {error}"),
        },
    }
}

pub fn default_prefer_tmux_terminal() -> bool {
    cfg!(unix) && !cfg!(windows)
}

pub fn prefer_tmux_env_override() -> Option<bool> {
    parse_bool_like(env::var(PREFER_TMUX_ENV).ok()?.as_str())
}

pub fn resolve_prefer_tmux_toggle(default_value: bool) -> bool {
    prefer_tmux_env_override().unwrap_or(default_value)
}

pub fn emit_warning_to_stderr(prefix: &str, warning: &TerminalLaunchWarning) {
    for line in warning.to_colored_lines(prefix) {
        eprintln!("{line}");
    }
}

pub fn build_tmux_missing_warning() -> TerminalLaunchWarning {
    TerminalLaunchWarning {
        code: "tmux_missing",
        message: "未检测到 tmux，已自动回退到内置终端实现。安装 tmux 可获得更稳定的共享终端体验。"
            .to_string(),
        install_commands: tmux_install_commands(),
    }
}

pub fn build_tmux_fallback_warning(error: &str) -> TerminalLaunchWarning {
    TerminalLaunchWarning {
        code: "tmux_fallback_warn",
        message: format!("tmux 启动失败，已自动回退到内置终端实现（fallback_warn）：{error}"),
        install_commands: Vec::new(),
    }
}

/// Sirix 管理的 tmux session 使用一组保守默认值：
/// - 关闭 status，避免把 tmux 自己的状态栏暴露给 Sirix 自定义终端渲染层
/// - 关闭 mouse，避免滚轮进入 tmux copy-mode 抢走历史滚动
///
/// 这里采用 best-effort 语义：调用方可以把失败视为告警后继续，而不是让会话直接中断。
pub fn apply_tmux_session_defaults(session_name: &str) -> anyhow::Result<()> {
    if cfg!(windows) {
        return Ok(());
    }
    run_tmux_set_option(session_name, "status", "off")
        .context("failed to disable tmux status bar")?;
    run_tmux_set_option(session_name, "mouse", "off")
        .context("failed to disable tmux mouse mode")?;
    Ok(())
}

fn run_tmux_set_option(session_name: &str, option: &str, value: &str) -> anyhow::Result<()> {
    let output = Command::new("tmux")
        .arg("set-option")
        .arg("-t")
        .arg(session_name)
        .arg(option)
        .arg(value)
        .output()
        .with_context(|| format!("failed to run tmux set-option for {option}"))?;
    if output.status.success() {
        return Ok(());
    }
    anyhow::bail!(
        "tmux set-option {} {} failed status={} stderr={}",
        option,
        value,
        output.status,
        String::from_utf8_lossy(&output.stderr)
    );
}

/// tmux 作为“被嵌入的终端客户端”时，向它暴露一个保守的 TERM 值会更稳定。
/// 当前 Sirix 的 Desktop App / system-terminal attach client 并不是完整的系统终端仿真器，
/// 避免让 tmux 走过于激进的 xterm 特性探测路径。
pub fn preferred_tmux_client_term() -> &'static str {
    "screen-256color"
}

fn tmux_install_commands() -> Vec<String> {
    if cfg!(target_os = "macos") {
        return vec!["brew install tmux".to_string()];
    }

    if cfg!(target_os = "linux") {
        let distro_hint = linux_distro_hint().unwrap_or_default();
        if distro_hint.contains("ubuntu")
            || distro_hint.contains("debian")
            || distro_hint.contains("mint")
        {
            return vec!["sudo apt update && sudo apt install -y tmux".to_string()];
        }
        if distro_hint.contains("fedora")
            || distro_hint.contains("rhel")
            || distro_hint.contains("centos")
            || distro_hint.contains("rocky")
            || distro_hint.contains("alma")
        {
            return vec!["sudo dnf install -y tmux".to_string()];
        }
        if distro_hint.contains("arch") || distro_hint.contains("manjaro") {
            return vec!["sudo pacman -S --noconfirm tmux".to_string()];
        }
        if distro_hint.contains("alpine") {
            return vec!["sudo apk add tmux".to_string()];
        }
        return vec![
            "sudo apt install -y tmux".to_string(),
            "sudo dnf install -y tmux".to_string(),
            "sudo pacman -S --noconfirm tmux".to_string(),
        ];
    }

    if cfg!(unix) {
        return vec!["pkg install tmux".to_string()];
    }

    Vec::new()
}

fn linux_distro_hint() -> Option<String> {
    let content = fs::read_to_string("/etc/os-release").ok()?;
    let mut id = String::new();
    let mut like = String::new();
    for line in content.lines() {
        if let Some(value) = line.strip_prefix("ID=") {
            id = trim_os_release_value(value).to_ascii_lowercase();
        } else if let Some(value) = line.strip_prefix("ID_LIKE=") {
            like = trim_os_release_value(value).to_ascii_lowercase();
        }
    }
    let merged = format!("{id} {like}").trim().to_string();
    if merged.is_empty() {
        None
    } else {
        Some(merged)
    }
}

fn trim_os_release_value(value: &str) -> &str {
    value.trim().trim_matches('"').trim_matches('\'')
}

fn parse_bool_like(value: &str) -> Option<bool> {
    match value.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" | "on" => Some(true),
        "0" | "false" | "no" | "off" => Some(false),
        _ => None,
    }
}

fn sanitize_tmux_session_seed(seed: &str) -> String {
    let mut sanitized = String::with_capacity(seed.len());
    for ch in seed.chars() {
        if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
            sanitized.push(ch);
        } else {
            sanitized.push('_');
        }
    }
    let sanitized = sanitized.trim_matches('_');
    if sanitized.is_empty() {
        "sirix-terminal-session".to_string()
    } else {
        sanitized.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolver_uses_legacy_when_toggle_off() {
        let resolver = TerminalLaunchResolver::default();
        let request = TerminalLaunchRequest {
            requested_shell: "/bin/zsh",
            cwd: None,
            prefer_tmux: false,
            tmux_session_seed: "abc",
        };
        let probe = TmuxAvailability {
            available: true,
            detail: "tmux 3.4".to_string(),
        };
        let selection = resolver.resolve(&request, &probe);
        assert_eq!(
            selection.primary.strategy,
            TerminalLaunchStrategyKind::LegacyShell
        );
        assert!(selection.fallback.is_none());
    }

    #[test]
    fn resolver_warns_and_falls_back_when_tmux_missing() {
        let resolver = TerminalLaunchResolver::default();
        let request = TerminalLaunchRequest {
            requested_shell: "/bin/bash",
            cwd: None,
            prefer_tmux: true,
            tmux_session_seed: "abc",
        };
        let probe = TmuxAvailability {
            available: false,
            detail: "not found".to_string(),
        };
        let selection = resolver.resolve(&request, &probe);
        assert_eq!(
            selection.primary.strategy,
            TerminalLaunchStrategyKind::LegacyShell
        );
        if !cfg!(windows) {
            assert!(!selection.warnings.is_empty());
            assert_eq!(selection.warnings[0].code, "tmux_missing");
        }
    }

    #[test]
    fn resolver_uses_tmux_when_available_and_enabled() {
        let resolver = TerminalLaunchResolver::default();
        let request = TerminalLaunchRequest {
            requested_shell: "/bin/bash",
            cwd: Some(Path::new("/tmp")),
            prefer_tmux: true,
            tmux_session_seed: "sirix-test",
        };
        let probe = TmuxAvailability {
            available: true,
            detail: "tmux 3.4".to_string(),
        };
        let selection = resolver.resolve(&request, &probe);
        if cfg!(windows) {
            assert_eq!(
                selection.primary.strategy,
                TerminalLaunchStrategyKind::LegacyShell
            );
        } else {
            assert_eq!(
                selection.primary.strategy,
                TerminalLaunchStrategyKind::TmuxShell
            );
            assert!(selection.fallback.is_some());
            assert_eq!(selection.primary.program, "tmux");
            assert!(
                selection.primary.args.iter().all(|arg| arg != ";"),
                "tmux startup should not rely on inline command separators after attach"
            );
        }
    }

    #[test]
    fn sanitize_session_seed_never_returns_empty() {
        assert_eq!(
            sanitize_tmux_session_seed(":::"),
            "sirix-terminal-session".to_string()
        );
        assert_eq!(sanitize_tmux_session_seed("a b c"), "a_b_c".to_string());
    }

    #[test]
    fn warning_lines_use_ansi_yellow() {
        let warning = build_tmux_missing_warning();
        let lines = warning.to_colored_lines("sirix");
        assert!(lines.iter().all(|line| line.contains(ANSI_YELLOW)));
    }
}
