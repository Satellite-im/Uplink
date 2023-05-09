use dioxus::prelude::*;
use warp::constellation::file::File;

#[inline_props]
#[allow(non_snake_case)]
pub fn FilePreview(cx: Scope, file: File) -> Element {
    let thumbnail = file.thumbnail();

    cx.render(rsx! (
        div {
            {
                rsx!{
                    div {
                        img {
                            src: "{thumbnail}",
                            position: "absolute",
                            top: "50%",
                            left: "50%",
                            transform: "translate(-50%, -50%)",
                            max_height: "80%",
                            max_width: "80%",
                        },
                    }
                }
            }
        },
    ))
}
