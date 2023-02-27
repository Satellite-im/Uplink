use std::{ffi::OsStr, path::PathBuf};

use dioxus::prelude::*;
use dioxus_elements::input_data::keyboard_types::Code;
use uuid::Uuid;

use crate::elements::{
    button::Button,
    input::{Input, Options, Size, SpecialCharsAction, Validation},
    Appearance,
};
use common::icons::outline::Shape as Icon;
use common::icons::Icon as IconElement;
const MAX_LEN_TO_FORMAT_NAME: usize = 15;

pub const VIDEO_FILE_EXTENSIONS: &[&str] = &[
    ".mp4", ".mov", ".mkv", ".avi", ".flv", ".wmv", ".m4v", ".3gp",
];

#[derive(Props)]
pub struct Props<'a> {
    text: String,
    #[props(optional)]
    thumbnail: Option<String>,
    #[props(optional)]
    disabled: Option<bool>,
    #[props(optional)]
    aria_label: Option<String>,
    #[props(optional)]
    with_rename: Option<bool>,
    #[props(optional)]
    onrename: Option<EventHandler<'a, (String, Code)>>,
    #[props(optional)]
    onpress: Option<EventHandler<'a>>,
    #[props(optional)]
    loading: Option<bool>,
}

pub fn get_text(file_name: String) -> (String, String) {
    let mut file_name_formatted = file_name.clone();
    let item = PathBuf::from(&file_name);
    let file_extension = get_file_extension(file_name.clone());

    let file_stem = item
        .file_stem()
        .and_then(OsStr::to_str)
        .map(str::to_string)
        .unwrap_or_default();

    if file_stem.len() > MAX_LEN_TO_FORMAT_NAME {
        file_name_formatted = match &file_name.get(0..7) {
            Some(name_sliced) => format!(
                "{}...{}{}",
                name_sliced,
                &file_stem[file_stem.len() - 2..].to_string(),
                file_extension
            ),
            None => file_name.clone(),
        };
    }
    (file_name, file_name_formatted)
}

pub fn is_video(file_name: String) -> bool {
    let video_formats = VIDEO_FILE_EXTENSIONS.to_vec();
    let file_extension = get_file_extension(file_name);

    video_formats.iter().any(|f| f == &file_extension)
}

pub fn get_aria_label(cx: &Scope<Props>) -> String {
    cx.props.aria_label.clone().unwrap_or_default()
}

pub fn emit(cx: &Scope<Props>, s: String, key_code: Code) {
    if let Some(f) = cx.props.onrename.as_ref() {
        f.call((s, key_code))
    }
}

pub fn emit_press(cx: &Scope<Props>) {
    if let Some(f) = cx.props.onpress.as_ref() {
        f.call(())
    }
}

pub fn get_file_extension(file_name: String) -> String {
    // don't append a '.' to a file name if it has no extension
    std::path::Path::new(&file_name)
        .extension()
        .and_then(OsStr::to_str)
        .map(|s| format!(".{s}"))
        .unwrap_or_default()
}

#[allow(non_snake_case)]
pub fn File<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let file_extension = get_file_extension(cx.props.text.clone());
    let (file_name, file_name_formatted) = get_text(cx.props.text.clone());
    let aria_label = get_aria_label(&cx);
    let placeholder = file_name;
    let with_rename = cx.props.with_rename.unwrap_or_default();
    let disabled = cx.props.disabled.unwrap_or_default();
    let thumbnail = cx.props.thumbnail.clone().unwrap_or_default();
    let is_video = is_video(cx.props.text.clone());

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
                    div {
                        position: "relative",
                        if thumbnail.is_empty() {
                            rsx!(IconElement {
                                icon: Icon::Document,
                            })
                        } else {
                            rsx!(img {
                                class: "thumbnail-container",
                                src: "{thumbnail}",
                            })
                        }
                        if is_video {
                            rsx!(div {
                                class: "play-button",
                                Button {
                                    icon: Icon::Play,
                                    appearance: Appearance::Transparent,
                                    small: true,
                                }
                            })
                        }
                    },
                },
                with_rename.then(||
                    rsx! (
                        Input {
                                id: Uuid::new_v4().to_string(),
                                disabled: disabled,
                                placeholder: placeholder,
                                focus: true,
                                max_length: 64,
                                size: Size::Small,
                                options: Options {
                                    react_to_esc_key: true,
                                    with_validation: Some(Validation {
                                        alpha_numeric_only: true,
                                        special_chars: Some((SpecialCharsAction::Block, vec!['\\', '/'])),
                                        ..Validation::default()
                                    }),
                                    ..Options::default()
                                }
                                // todo: use is_valid
                                onreturn: move |(s, is_valid, key_code)| {
                                    if is_valid  {
                                        let new_name = format!("{}{}", s, file_extension);
                                        emit(&cx, new_name, key_code)
                                    }
                                }
                            }
                        )
                  ),
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

    #[test]
    fn test_get_file_extension1() {
        let input = String::from("image.jpeg");
        let file_extension = get_file_extension(input);
        assert_eq!(file_extension, ".jpeg");
    }

    #[test]
    fn test_get_file_extension2() {
        let input = String::from("image.png");
        let file_extension = get_file_extension(input);
        assert_eq!(file_extension, ".png");
    }

    #[test]
    fn test_get_file_extension3() {
        let input = String::from("file.txt");
        let file_extension = get_file_extension(input);
        assert_eq!(file_extension, ".txt");
    }

    #[test]
    fn test_get_file_extension4() {
        let input = String::from("file.txt.exe");
        let file_extension = get_file_extension(input);
        assert_eq!(file_extension, ".exe");
    }

    #[test]
    fn test_get_file_extension5() {
        let input = String::from("file");
        let file_extension = get_file_extension(input);
        assert_eq!(file_extension, "");
    }
}
