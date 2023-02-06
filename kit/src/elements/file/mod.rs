use std::{ffi::OsStr, path::PathBuf};

use dioxus::prelude::*;

use crate::{
    elements::input::Input,
    icons::{Icon, IconElement},
};
const MAX_LEN_TO_FORMAT_NAME: usize = 15;

#[derive(Props)]
pub struct Props<'a> {
    #[props(optional)]
    text: Option<String>,
    #[props(optional)]
    disabled: Option<bool>,
    #[props(optional)]
    aria_label: Option<String>,
    #[props(optional)]
    with_rename: Option<bool>,
    #[props(optional)]
    onrename: Option<EventHandler<'a, String>>,
    #[props(optional)]
    onpress: Option<EventHandler<'a>>,
    #[props(optional)]
    loading: Option<bool>,
}

pub fn get_text(file_name: String) -> (String, String) {
    let mut file_name_formatted = file_name.clone();
    let file_extension = std::path::Path::new(&file_name)
        .extension()
        .and_then(OsStr::to_str)
        .unwrap_or_default();
    let item = PathBuf::from(&file_name);
    let file_stem = item
        .file_stem()
        .and_then(OsStr::to_str)
        .map(str::to_string)
        .unwrap_or_default();

    if file_stem.len() > MAX_LEN_TO_FORMAT_NAME {
        file_name_formatted = match &file_name.to_string().get(0..7) {
            Some(name_sliced) => format!(
                "{}...{}.{}",
                name_sliced,
                &file_stem[file_stem.len() - 2..].to_string(),
                file_extension
            ),
            None => file_name.clone(),
        };
    }
    (file_name, file_name_formatted)
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
pub fn File<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let (file_name, file_name_formatted) = get_text(cx.props.text.clone().unwrap_or_default());
    let aria_label = get_aria_label(&cx);
    let placeholder = file_name.clone();
    let with_rename = cx.props.with_rename.unwrap_or_default();
    let disabled = cx.props.disabled.unwrap_or_default();

    let loading = cx.props.loading.unwrap_or_default();

    if loading {
        cx.render(rsx!(FileSkeletal {}))
    } else {
        cx.render(rsx!(
            div {
                class: {
                    format_args!("file {}", if disabled { "disabled" } else { "" })
                },
                aria_label: "{aria_label}",
                div {
                    class: "icon",
                    onclick: move |_| emit_press(&cx),
                    IconElement {
                        icon: Icon::Document,
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
                        class: "file-name",
                        "{file_name_formatted}"
                    }
                ))
            }
        ))
    }
}

#[allow(non_snake_case)]
pub fn FileSkeletal(cx: Scope) -> Element {
    cx.render(rsx!(
        div {
            class: "file",
            div {
                class: "icon skeletal-svg",
                IconElement {
                    icon: Icon::DocumentText,
                },
            },
            div {
                class: "skeletal skeletal-bar"
            }
        }
    ))
}

#[cfg(test)]
mod test {
    pub use super::*;

    #[test]
    fn test_get_text1() {
        let input = String::from("very_long_file_name.txt");
        let (name, formatted) = get_text(input.clone());
        assert_eq!(input, name);
        assert_eq!(formatted, String::from("very_lo...me.txt"));
    }

    #[test]
    fn test_get_text2() {
        let input = String::from("very_long_file_name");
        let (name, formatted) = get_text(input.clone());
        assert_eq!(input, name);
        assert_eq!(formatted, String::from("very_lo...me"));
    }

    #[test]
    fn test_get_text3() {
        let input = String::from("name.txt");
        let (name, formatted) = get_text(input.clone());
        assert_eq!(input, name);
        assert_eq!(formatted, input);
    }

    #[test]
    fn test_get_text4() {
        let input = String::from("name");
        let (name, formatted) = get_text(input.clone());
        assert_eq!(input, name);
        assert_eq!(formatted, input);
    }
}
