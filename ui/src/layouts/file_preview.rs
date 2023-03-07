use dioxus::prelude::*;

use common::icons::Icon as IconElement;
use common::{icons::outline::Shape as Icon, VIDEO_FILE_EXTENSIONS};
use kit::elements::{
    button::Button,
    file::is_video,
    tooltip::{ArrowPosition, Tooltip},
    Appearance,
};
use warp::constellation::file::File;

use crate::{window_manager::WindowManagerCmd, WINDOW_CMD_CH};

use super::storage::WindowDropHandler;

enum FileFormat {
    Video,
    Image,
    Document,
    Other,
}

// pub fn get_file_format(file_name: String) -> bool {
//     // let video_formats = VIDEO_FILE_EXTENSIONS.to_vec();

//     // let file_extension = get_file_extension(file_name);

//     // video_formats.iter().any(|f| f == &file_extension)
// }

#[inline_props]
#[allow(non_snake_case)]
pub fn FilePreview(cx: Scope, _drop_handler: WindowDropHandler, file: File) -> Element {
    let cmd_tx = WINDOW_CMD_CH.tx.clone();
    let is_video = is_video(file.name());

    cx.render(
        rsx! (
        div {
            id: "video-poped-out",
            class: "popout-player",
            div {
                class: "wrap",
                video {
                    src: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/Sintel.mp4",
                    autoplay: "true",
                    "loop": "false",
                    muted: "false"
                },
                div {
                    class: "controls",
                    Button {
                        icon: Icon::XMark,
                        appearance: Appearance::Transparent,
                        tooltip: cx.render(rsx!(
                            Tooltip {
                                arrow_position: ArrowPosition::Left,
                                text: String::from("Close")
                            }
                        )),
                        onpress: move |_| {
                            if let Err(_e) = cmd_tx.send(WindowManagerCmd::ClosePopout) {
                                //todo: log error
                            }
                        }
                    },
                    Button {
                        icon: Icon::ArrowsPointingOut,
                        appearance: Appearance::Transparent,
                        tooltip: cx.render(rsx!(
                            Tooltip {
                                arrow_position: ArrowPosition::Right,
                                text: String::from("Fullscreen")
                            }
                        )),
                    }
                }
            },
        },
    ))
}
