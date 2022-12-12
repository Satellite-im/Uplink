use dioxus::{prelude::*, events::MouseEvent};

use crate::{User, components::user_image::UserImage};


#[derive(Props)]
pub struct Props<'a> {
    participants: Vec<User>,
    #[props(optional)]
    onpress: Option<EventHandler<'a, MouseEvent>>,
    #[props(optional)]
    typing: Option<bool>,
}

#[allow(non_snake_case)]
pub fn UserImageGroup<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let pressable = &cx.props.onpress.is_some();

    let count: i64 = cx.props.participants.len() as i64 - 3;

    cx.render(rsx! (
        div {
            class: {
                format_args!("user-image-group-wrap {} four-or-more", if *pressable { "pressable" } else { "" })
            },
            cx.props.participants.iter().map(|user| {
                rsx!(
                    UserImage {
                        platform: user.platform,
                        status: user.status
                    }
                )
            })
            div {
                class: "plus-some",
                (count > 0).then(|| rsx!(
                    p {
                        "+{count}"
                    }
                ))
            }
        }
    ))
}
