use common::language::{get_local_text, get_local_text_with_args};
use dioxus::prelude::*;

const MAX_LEN: usize = 17;

#[derive(Props, PartialEq, Clone)]
pub struct Props {
    // Represents the image of the user who is typing
    typing_users: Vec<String>,
}

#[allow(non_snake_case)]
pub fn MessageTyping(props: Props) -> Element {
    let typing_users = if props.typing_users.len() > 3 {
        get_local_text("messages.users-multiple-typing")
    } else {
        let (translation, key) = if props.typing_users.len() == 1 {
            ("messages.user-typing", "user")
        } else {
            ("messages.users-typing", "users")
        };
        let mut users = props.typing_users.join(", ");
        let users = if users.len() > MAX_LEN {
            let mut users: String = users.drain(..(MAX_LEN - 3)).collect();
            users.push_str("...");
            users
        } else {
            users
        };
        get_local_text_with_args(translation, vec![(key, users)])
    };

    rsx! (
        div {
            class: "message-typing-wrap",
            // TODO: Support a vec of user images in case multiple are typing
            div {
                class: "message-typing",
                aria_label: "message-typing-indicator",
                p {
                    class: "typing-message",
                    aria_label: "typing-message",
                    {typing_users},
                }
                div {
                    display: "flex",
                    gap: "var(--gap-less)",
                    div { class: "dot dot-1" },
                    div { class: "dot dot-2" },
                    div { class: "dot dot-3" }
                }
            }
        }
    )
}
