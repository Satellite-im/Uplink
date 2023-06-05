use common::{get_images_dir, state::State};
use dioxus::prelude::*;
use dioxus_desktop::{use_window, LogicalSize};
use dioxus_router::use_router;
use futures::channel::oneshot;

use crate::{utils::unzip_prism_langs, UPLINK_ROUTES};

#[allow(non_snake_case)]
pub fn LoadingLayout(cx: Scope) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let router = use_router(cx);
    let desktop = use_window(cx);

    let desktop_resized = use_future(cx, (), |_| {
        to_owned![desktop];
        async move {
            // Here we set the size larger, and bump up the min size in preparation for rendering the main app.
            desktop.set_inner_size(LogicalSize::new(950.0, 600.0));
            desktop.set_min_inner_size(Some(LogicalSize::new(300.0, 500.0)));
        }
    });

    let fut = use_future(cx, (), |_| async move {
        let (tx, rx) = oneshot::channel::<()>();
        std::thread::spawn(|| {
            unzip_prism_langs();
            let _ = tx.send(());
        });
        let _ = rx.await;
    });

    if fut.value().is_some() && desktop_resized.value().is_some() && state.read().initialized {
        router.replace_route(UPLINK_ROUTES.chat, None, None);
    }
    let desktop = use_window(cx);
    if state.read().ui.window_maximized {
        desktop.set_inner_size(LogicalSize {
            width: state.read().ui.window_width,
            height: state.read().ui.window_height,
        });
    }

    let img_path = get_images_dir().unwrap_or_default().join("uplink.gif");
    let img_path = img_path.to_string_lossy().to_string();
    cx.render(rsx!(img {
        style: "width: 100%",
        src: "{img_path}"
    }))
}
