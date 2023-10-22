use crate::utils::get_drag_event::DRAG_EVENT;
use common::STATIC_ARGS;
use dioxus_desktop::Config;
use warp::logging::tracing::log;

pub(crate) fn webview_config() -> Config {
    let window = crate::window_builder::get_window_builder(true);
    let config = Config::new()
        .with_window(window)
        .with_custom_index(
            r#"
            <!doctype html>
            <html>
            <script src="https://cdn.jsdelivr.net/npm/interactjs/dist/interact.min.js"></script>
            <body style="background-color:rgba(0,0,0,0);"><div id="main"></div></body>
            </html>"#
                .to_string(),
        )
        .with_file_drop_handler(|_w, drag_event| {
            log::info!("Drag Event: {:?}", drag_event);
            *DRAG_EVENT.write() = drag_event;
            true
        });

    if cfg!(target_os = "windows") && STATIC_ARGS.production_mode {
        let webview_data_dir = STATIC_ARGS.dot_uplink.join("tmp");
        std::fs::create_dir_all(&webview_data_dir).expect("error creating webview data directory");
        config.with_data_directory(webview_data_dir)
    } else {
        config
    }
}
