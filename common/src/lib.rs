pub mod language;
pub mod notifications;
pub mod sounds;
pub mod state;
pub mod testing;
pub mod warp_runner;

use clap::Parser;
// export icons crate
pub use icons;
use once_cell::sync::Lazy;
use std::{
    path::{Path, PathBuf},
    sync::Arc,
};
use tokio::sync::Mutex;
use warp_runner::{WarpCmdChannels, WarpEventChannels};

use fluent_templates::static_loader;

static_loader! {
    static LOCALES = {
        locales: "./locales",
        fallback_language: "en-US",
        // Removes unicode isolating marks around arguments, you typically
        // should only set to false when testing.
        customise: |bundle| bundle.set_use_isolating(false),
    };
}

// note that Trace and Trace2 are both LevelFilter::Trace. higher trace levels like Trace2
// enable tracing from modules besides Uplink
#[derive(clap::Subcommand, Debug)]
pub enum LogProfile {
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
pub struct Args {
    /// The location to store the .uplink directory, within which a .warp, state.json, and other useful logs will be located
    #[clap(long)]
    path: Option<PathBuf>,
    #[clap(long)]
    experimental_node: bool,
    #[cfg(debug_assertions)]
    #[clap(long, default_value_t = false)]
    with_mock: bool,
    /// configures log output
    #[command(subcommand)]
    pub profile: Option<LogProfile>,
}

#[derive(Debug)]
pub struct StaticArgs {
    /// ~/.uplink
    pub dot_uplink: PathBuf,
    /// Uplink stores its data with the following layout, starting at whatever the root folder is:
    /// ./uplink ./uplink/warp ./themes
    /// uplink_path is used for deleting all uplink data when a new account is created
    pub uplink_path: PathBuf,
    pub extras_path: PathBuf,
    /// does nothing until themes are properly bundled with the app. maybe one day we will have an installer that does this
    pub themes_path: PathBuf,
    /// Location of custom fonts added into the application (as well as a few defaults)
    pub fonts_path: PathBuf,
    /// state.json: a serialized version of State which gets saved every time state is modified
    pub cache_path: PathBuf,
    /// a fake tesseract_path to prevent anything from mutating the tesseract keypair after it has been created (probably not necessary)
    pub mock_cache_path: PathBuf,
    /// houses warp specific data
    pub warp_path: PathBuf,
    /// a debug log which is only written to when the settings are enabled. otherwise logs are only sent to stdout
    pub logger_path: PathBuf,
    /// contains the keypair used for IPFS
    pub tesseract_path: PathBuf,
    /// the unlock and auth pages don't have access to State but need to know if they should play a notification.
    /// part of state is serialized and saved here
    pub login_config_path: PathBuf,
    /// todo: document
    pub extensions_path: PathBuf,
    /// seconds
    pub typing_indicator_refresh: u64,
    /// seconds
    pub typing_indicator_timeout: u64,
    /// used only for testing the UI. generates fake friends, conversations, and messages
    pub use_mock: bool,
    /// Uses experimental configuration
    pub experimental: bool,
    // some features aren't ready for release. This field is used to disable such features.
    pub production_mode: bool,
}
pub static STATIC_ARGS: Lazy<StaticArgs> = Lazy::new(|| {
    let args = Args::parse();
    // the assets are fetched differently depending on whether the binary is in production mode or not.
    // sometimes we want to test the "release" profile without having to install the program the way a customer would.
    let override_release_mode = std::env::var("DEBUG").is_ok();
    let production_mode = !cfg!(debug_assertions) && !override_release_mode;

    #[allow(unused_mut)]
    #[allow(unused_assignments)]
    let mut use_mock = false;
    #[cfg(debug_assertions)]
    {
        use_mock = args.with_mock;
    }

    let uplink_container = match args.path {
        Some(path) => path,
        _ => dirs::home_dir().unwrap_or_default().join(".uplink"),
    };

    let uplink_path = uplink_container.join(".user");
    let warp_path = uplink_path.join("warp");
    let extras_path = if production_mode {
        uplink_container.join("extra")
    } else {
        Path::new("ui").join("extra")
    };
    StaticArgs {
        dot_uplink: uplink_container.clone(),
        uplink_path: uplink_path.clone(),
        extras_path: extras_path.clone(),
        themes_path: extras_path.join("themes"),
        fonts_path: extras_path.join("fonts"),
        cache_path: uplink_path.join("state.json"),
        extensions_path: uplink_container.join("extensions"),
        mock_cache_path: uplink_path.join("mock-state.json"),
        warp_path: warp_path.clone(),
        logger_path: uplink_path.join("debug.log"),
        typing_indicator_refresh: 5,
        typing_indicator_timeout: 6,
        tesseract_path: warp_path.join("tesseract.json"),
        login_config_path: uplink_path.join("login_config.json"),
        use_mock,
        experimental: args.experimental_node,
        production_mode,
    }
});

// allows the UI to send commands to Warp
pub static WARP_CMD_CH: Lazy<WarpCmdChannels> = Lazy::new(|| {
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
    WarpCmdChannels {
        tx,
        rx: Arc::new(Mutex::new(rx)),
    }
});

// allows the UI to receive events to Warp
// pretty sure the rx channel needs to be in a mutex in order for it to be a static mutable variable
pub static WARP_EVENT_CH: Lazy<WarpEventChannels> = Lazy::new(|| {
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
    WarpEventChannels {
        tx,
        rx: Arc::new(Mutex::new(rx)),
    }
});

pub const VIDEO_FILE_EXTENSIONS: &[&str] = &[
    ".mp4", ".mov", ".mkv", ".avi", ".flv", ".wmv", ".m4v", ".3gp",
];

pub const IMAGE_EXTENSIONS: &[&str] = &[
    ".png", ".jpg", ".jpeg", ".svg", ".heic", ".tiff", ".gif", ".webp", ".apng", ".avif", ".ico",
    ".bmp", ".svgz",
];

pub const DOC_EXTENSIONS: &[&str] = &[".doc", ".docx", ".pdf", ".txt"];
