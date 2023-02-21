use dioxus::prelude::*;
use uuid::Uuid;

use crate::elements::input::{Input, Options, Size, Validation, SPECIAL_CHARS};

use common::icons::outline::Shape as Icon;
use common::icons::Icon as IconElement;
const MAX_LEN_TO_FORMAT_NAME: usize = 15;

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

pub fn get_text(folder_name: String) -> (String, String) {
    let mut folder_name_formatted = folder_name.clone();

    if folder_name_formatted.len() > MAX_LEN_TO_FORMAT_NAME {
        folder_name_formatted = match &folder_name_formatted.get(0..12) {
            Some(name_sliced) => format!(
                "{}...{}",
                name_sliced,
                &folder_name_formatted[folder_name_formatted.len() - 3..].to_string(),
            ),
            None => folder_name_formatted.clone(),
        };
    }
    (folder_name, folder_name_formatted)
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
    let (folder_name, folder_name_formatted) = get_text(cx.props.text.clone().unwrap_or_default());
    let aria_label = get_aria_label(&cx);
    let placeholder = folder_name;
    let with_rename = cx.props.with_rename.unwrap_or_default();
    let icon = if open { Icon::FolderOpen } else { Icon::Folder };
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
                with_rename.then(||
                    {
                    let chars_to_remove = vec!['\\', '/'];
                    let mut special_chars = SPECIAL_CHARS.to_vec();
                    special_chars = special_chars
                        .iter()
                        .filter(|&&c| !chars_to_remove.contains(&c))
                        .cloned()
                        .collect();
                        rsx! (
                            Input {
                                id: Uuid::new_v4().to_string(),
                                disabled: disabled,
                                placeholder: placeholder,
                                focus: true,
                                max_length: 64,
                                size: Size::Small,
                                options: Options {
                                    with_validation: Some(Validation {
                                        alpha_numeric_only: true,
                                        special_chars_allowed: Some(special_chars),
                                        ..Validation::default()
                                    }),
                                    ..Options::default()
                                }
                                // todo: use is_valid
                                onreturn: move |(s, _is_valid)| {
                                    if _is_valid {
                                        emit(&cx, s);
                                    }
                                }
                            }
                    )
                    }
                  ),
                (!with_rename).then(|| rsx! (
                    label {
                        class: "folder-name",
                        "{folder_name_formatted}"
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

#[cfg(test)]
mod test {
    pub use super::*;

    #[test]
    fn test_get_text1() {
        let input = String::from("very_long_folder_name_test");
        let (name, formatted) = get_text(input.clone());
        assert_eq!(input, name);
        assert_eq!(formatted, String::from("very_long_fo...est"));
    }

    #[test]
    fn test_get_text2() {
        let input = String::from("very_long_folder_name");
        let (name, formatted) = get_text(input.clone());
        assert_eq!(input, name);
        assert_eq!(formatted, String::from("very_long_fo...ame"));
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

    #[test]
    fn test_get_text5() {
        let input = String::from("very_long_folder_name_with_dot.exe");
        let (name, formatted) = get_text(input.clone());
        assert_eq!(input, name);
        assert_eq!(formatted, String::from("very_long_fo...exe"));
    }
}
