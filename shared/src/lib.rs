pub mod config;
pub mod icons;
pub mod language;
pub mod notifications;
pub mod sounds;
pub mod state;
pub mod testing;

use clap::Parser;
use once_cell::sync::Lazy;
use std::path::PathBuf;

use fluent_templates::static_loader;

#[derive(clap::Subcommand, Debug)]
enum LogProfile {
    /// normal operation
    Normal,
    /// print everything but tracing logs to the terminal
    Debug,
    /// print everything including tracing logs to the terminal
    Trace,
    /// like trace but include warp logs
    Trace2,
}

#[derive(Debug, Parser)]
#[clap(name = "")]
struct Args {
    /// The location to store the .uplink directory, within which a .warp, state.json, and other useful logs will be located
    #[clap(long)]
    path: Option<PathBuf>,
    #[clap(long)]
    experimental_node: bool,
    // todo: hide mock behind a #[cfg(debug_assertions)]
    #[clap(long, default_value_t = false)]
    with_mock: bool,
    /// configures log output
    #[command(subcommand)]
    profile: Option<LogProfile>,
}

#[derive(Debug)]
pub struct StaticArgs {
    pub uplink_path: PathBuf,
    pub themes_path: PathBuf,
    pub cache_path: PathBuf,
    pub mock_cache_path: PathBuf,
    pub config_path: PathBuf,
    pub extensions_path: PathBuf,
    pub warp_path: PathBuf,
    pub logger_path: PathBuf,
    pub tesseract_path: PathBuf,
    // seconds
    pub typing_indicator_refresh: u64,
    // seconds
    pub typing_indicator_timeout: u64,
    pub use_mock: bool,
}
pub static STATIC_ARGS: Lazy<StaticArgs> = Lazy::new(|| {
    let args = Args::parse();
    let uplink_container = match args.path {
        Some(path) => path,
        _ => dirs::home_dir().unwrap_or_default().join(".uplink"),
    };
    let warp_path = uplink_container.join("warp");
    StaticArgs {
        uplink_path: uplink_container.clone(),
        themes_path: uplink_container.join("themes"),
        cache_path: uplink_container.join("state.json"),
        extensions_path: uplink_container.join("extensions"),
        mock_cache_path: uplink_container.join("mock-state.json"),
        config_path: uplink_container.join("Config.json"),
        warp_path: warp_path.clone(),
        logger_path: uplink_container.join("debug.log"),
        typing_indicator_refresh: 5,
        typing_indicator_timeout: 6,
        tesseract_path: warp_path.join("tesseract.json"),
        use_mock: args.with_mock,
    }
});

static_loader! {
    static LOCALES = {
        locales: "./locales",
        fallback_language: "en-US",
        // Removes unicode isolating marks around arguments, you typically
        // should only set to false when testing.
        customise: |bundle| bundle.set_use_isolating(false),
    };
}
