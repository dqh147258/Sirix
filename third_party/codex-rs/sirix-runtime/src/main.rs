use clap::Parser;
use codex_arg0::Arg0DispatchPaths;
use codex_arg0::arg0_dispatch_or_else;
use codex_tui::Cli;
use codex_tui::run_main;
use codex_utils_cli::CliConfigOverrides;

const SIRIX_CONFIG_OVERRIDES_PATH_ENV: &str = "SIRIX_CONFIG_OVERRIDES_PATH";
const LEGACY_SIRIX_CONFIG_OVERRIDES_JSON_ENV: &str = "SIRIX_CONFIG_OVERRIDES_JSON";

#[derive(Parser, Debug)]
struct TopCli {
    #[clap(flatten)]
    config_overrides: CliConfigOverrides,

    #[clap(flatten)]
    inner: Cli,
}

fn main() -> anyhow::Result<()> {
    arg0_dispatch_or_else(|arg0_paths: Arg0DispatchPaths| async move {
        let top_cli = TopCli::parse();
        let mut inner = top_cli.inner;
        let env_overrides = load_sirix_env_overrides()?;
        inner.config_overrides.raw_overrides.splice(
            0..0,
            env_overrides
                .into_iter()
                .chain(top_cli.config_overrides.raw_overrides),
        );

        let exit_info = run_main(
            inner,
            arg0_paths,
            codex_core::config_loader::LoaderOverrides::default(),
            None,
            None,
        )
        .await?;

        let token_usage = exit_info.token_usage;
        if !token_usage.is_zero() {
            println!(
                "{}",
                codex_protocol::protocol::FinalOutput::from(token_usage),
            );
        }

        Ok(())
    })
}

fn load_sirix_env_overrides() -> anyhow::Result<Vec<String>> {
    if let Some(path) = std::env::var(SIRIX_CONFIG_OVERRIDES_PATH_ENV)
        .ok()
        .filter(|value| !value.trim().is_empty())
    {
        let raw = std::fs::read_to_string(&path).map_err(|error| {
            anyhow::anyhow!("failed to read {SIRIX_CONFIG_OVERRIDES_PATH_ENV}={path}: {error}")
        })?;
        return serde_json::from_str::<Vec<String>>(&raw)
            .map_err(|error| anyhow::anyhow!("invalid overrides file at {path}: {error}"));
    }

    let Some(raw) = std::env::var(LEGACY_SIRIX_CONFIG_OVERRIDES_JSON_ENV)
        .ok()
        .filter(|value| !value.trim().is_empty())
    else {
        return Ok(Vec::new());
    };

    serde_json::from_str::<Vec<String>>(&raw).map_err(|error| {
        anyhow::anyhow!("invalid {LEGACY_SIRIX_CONFIG_OVERRIDES_JSON_ENV}: {error}")
    })
}
