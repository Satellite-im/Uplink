use common::get_images_dir;
use common::state::{Action, State};
use dioxus::prelude::*;
use kit::layout::topbar::Topbar;

use crate::UPLINK_ROUTES;
use common::icons::outline::Shape as Icon;
use common::language::get_local_text;
use dioxus_router::prelude::use_router;
use kit::elements::{button::Button, Appearance};

#[allow(non_snake_case)]
pub fn Welcome(cx: Scope) -> Element {
    let router = use_router(cx).clone();
    let state = use_shared_state::<State>(cx)?;

    let cta_text = get_local_text("friends.cta-text");
    let image_path = get_images_dir()
        .unwrap_or_default()
        .join("mascot")
        .join("better_with_friends.webp")
        .to_str()
        .map(|x| x.to_string())
        .unwrap_or_default();
    cx.render(rsx! {
            div {
                id: "welcome",
                aria_label: "welcome-screen",
                if state.read().ui.sidebar_hidden {
                    rsx!(
                        Topbar {
                        with_back_button: state.read().ui.is_minimal_view() || state.read().ui.sidebar_hidden,
                        onback: move |_| {
                            let current = state.read().ui.sidebar_hidden;
                            state.write().mutate(Action::SidebarHidden(!current));
                        },
                    },)
                }
                img {
                    class: "image",
                    aria_label: "welcome-image",
                    src:"{image_path}"
                },
                p {
                    class: "muted",
                    "{cta_text}"
                },
                Button {
                    icon: Icon::Plus,
                    aria_label: "add-friends-button".into(),
                    text: get_local_text("friends.add"),
                    appearance: Appearance::Secondary,
                    onpress: move |_| {
                        router.replace(UPLINK_ROUTES.friends);
                    }
                },
            }
        })
}
