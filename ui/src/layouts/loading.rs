use std::collections::HashMap;

use common::{
    state::{State, Theme},
    STATIC_ARGS,
};
use dioxus::prelude::*;
use dioxus_router::use_router;
use extensions::UplinkExtension;
use futures::channel::oneshot;
use warp::logging::tracing::log;

use crate::{utils::unzip_prism_langs, UPLINK_ROUTES};

#[allow(non_snake_case)]
pub fn LoadingLayout(cx: Scope) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let router = use_router(cx);
    let state_init = use_state(cx, || false);

    // UplinkExtension can't be cloned and can't move out of a useFuture, so use this thing instead
    // makes use of Option::take()
    let fut_result: &UseRef<Option<(Vec<Theme>, HashMap<String, UplinkExtension>)>> =
        use_ref(cx, || None);

    use_future(cx, (), |_| {
        to_owned![fut_result];
        async move {
            // unzip_prism_langs is blocking. run it on a separate thread and not on the async runtime.
            let (tx, rx) = oneshot::channel::<()>();
            std::thread::spawn(|| {
                unzip_prism_langs();
                let _ = tx.send(());
            });
            let _ = rx.await;

            // get themes
            let (tx, rx) = oneshot::channel();
            std::thread::spawn(|| {
                let t = crate::utils::get_available_themes();
                let _ = tx.send(t);
            });
            let themes = rx.await.unwrap_or_default();

            // get extensions
            let (tx, rx) = oneshot::channel();
            std::thread::spawn(|| {
                let ext = crate::get_extensions().unwrap_or_default();
                let _ = tx.send(ext);
            });
            let extensions = rx.await.unwrap_or_default();

            fut_result.set(Some((themes, extensions)));
        }
    });

    if let Some((themes, extensions)) = fut_result.write().take() {
        if !*state_init.current() {
            let theme = themes.iter().find(|t| {
                state
                    .write()
                    .ui
                    .theme
                    .as_ref()
                    .map(|theme| theme.eq(t))
                    .unwrap_or_default()
            });
            if let Some(t) = theme {
                state.write().set_theme(Some(t.clone()));
            }

            for (name, extension) in extensions {
                state.write().ui.extensions.insert(name, extension);
            }
            log::debug!(
                "Loaded {} extensions.",
                state.read().ui.extensions.values().count()
            );
            state_init.set(true);
        }
    }

    if state.read().chats().initialized
        && state.read().friends().initialized
        && *state_init.current()
    {
        router.replace_route(UPLINK_ROUTES.chat, None, None);
    }

    let img_path = STATIC_ARGS
        .extras_path
        .join("assets")
        .join("img")
        .join("uplink.gif");
    let img_path = img_path.to_string_lossy().to_string();
    cx.render(rsx!(img {
        style: "width: 100%",
        src: "{img_path}"
    }))
}
