use common::{language::get_local_text, state::State};
use dioxus::prelude::*;

#[derive(Props, PartialEq)]
pub struct Props {
    // The filename of the file
    friends_tab: String,
}

#[allow(non_snake_case)]
pub fn NothingHere(cx: Scope<Props>) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let pending_friends =
        state.read().incoming_fr_identities().len() + state.read().outgoing_fr_identities().len();
    let blocked_friends = state.read().blocked_fr_identities().len();
    let message_text = get_local_text("friends.nothing-to-see-here");
    let show_warning = match cx.props.friends_tab.as_str() {
        "Pending" => pending_friends == 0,
        "Blocked" => blocked_friends == 0,
        _ => false,
    };

    cx.render(rsx!(if show_warning {
        rsx!(div {
            class: "friends-list",
            aria_label: "no-requests",
            p {
                class: "no-friends-text",
                "{message_text}"
            }
        })
    } else {
        rsx!({})
    }))
}
