use dioxus::prelude::*;

use crate::{
    elements::input::Input,
    icons::{Icon, IconElement},
};

#[derive(Props)]
pub struct Props<'a> {
    #[props(optional)]
    open: Option<bool>,
    #[props(optional)]
    text: Option<String>,
    #[props(optional)]
    aria_label: Option<String>,
    #[props(optional)]
    disabled: Option<bool>,
    #[props(optional)]
    with_rename: Option<bool>,
    #[props(optional)]
    onrename: Option<EventHandler<'a, String>>,
    #[props(optional)]
    onpress: Option<EventHandler<'a>>,
    #[props(optional)]
    loading: Option<bool>,
}

pub fn get_text(cx: &Scope<Props>) -> String {
    cx.props.text.clone().unwrap_or_default()
}

pub fn get_aria_label(cx: &Scope<Props>) -> String {
    cx.props.aria_label.clone().unwrap_or_default()
}

pub fn emit(cx: &Scope<Props>, s: String) {
    if let Some(f) = cx.props.onrename.as_ref() {
        f.call(s)
    }
}

pub fn emit_press(cx: &Scope<Props>) {
    if let Some(f) = cx.props.onpress.as_ref() {
        f.call(())
    }
}

#[allow(non_snake_case)]
pub fn Folder<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let open = cx.props.open.unwrap_or_default();
    let text = get_text(&cx);
    let aria_label = get_aria_label(&cx);
    let placeholder = text.clone();
    let with_rename = cx.props.with_rename.unwrap_or_default();
    let icon = if open {
        Icon::FolderOpen
    } else {
        Icon::Folder
    };
    let disabled = cx.props.disabled.unwrap_or_default();

    let loading = cx.props.loading.unwrap_or_default();

    if loading {
        cx.render(rsx!(FolderSkeletal {}))
    } else {
        cx.render(rsx!(
            div {
                class: {
                    format_args!("folder {}", if disabled { "disabled" } else { "" })
                },
                aria_label: "{aria_label}",
                div {
                    class: "icon",
                    onclick: move |_| emit_press(&cx),
                    IconElement {
                        icon: icon,
                    },
                },
                with_rename.then(|| rsx! (
                    Input {
                        disabled: disabled,
                        placeholder: placeholder,
                        // todo: use is_valid
                        onreturn: move |(s, _is_valid)| emit(&cx, s)
                    }
                )),
                (!with_rename).then(|| rsx! (
                    label {
                        "{text}"
                    }
                ))
            }
        ))
    }
}

#[allow(non_snake_case)]
pub fn FolderSkeletal(cx: Scope) -> Element {
    cx.render(rsx!(
        div {
            class: "folder",
            div {
                class: "icon skeletal-svg",
                IconElement {
                    icon: Icon::FolderArrowDown,
                },
            },
            div {
                class: "skeletal skeletal-bar"
            }
        }
    ))
}
