use common::state::State;
use dioxus::prelude::*;
use dioxus_desktop::wry::application::dpi::LogicalPosition;
use dioxus_desktop::LogicalSize;

pub fn LoadingWash() -> Element {
    let img_path = cx.use_hook(|| {
        common::get_images_dir()
            .unwrap_or_default()
            .join("uplink.gif")
            .to_string_lossy()
            .to_string()
    });

    render! {
        img {
            style: "width: 100%",
            src: "{img_path}"
        }
    }
}

pub fn use_loaded_assets() -> &UseFuture<Result<(), tokio::task::JoinError>> {
    let desktop = dioxus_desktop::use_window(cx);
    let state = use_shared_state::<State>(cx).unwrap();

    use_future(cx, (), |_| {
        to_owned![desktop, state];
        async move {
            let res = tokio::task::spawn_blocking(|| {
                crate::utils::unzip_prism_langs();
            })
            .await;

            // Here we set the size larger, and bump up the min size in preparation for rendering the main app.
            if state.read().ui.window_maximized {
                desktop.set_outer_position(LogicalPosition::new(0, 0));
                desktop.set_maximized(true);
            } else {
                desktop.set_inner_size(LogicalSize::new(950.0, 600.0));
            }
            desktop.set_min_inner_size(Some(LogicalSize::new(300.0, 500.0)));

            res
        }
    })
}
