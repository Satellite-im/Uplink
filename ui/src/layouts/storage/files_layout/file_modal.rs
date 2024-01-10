use std::path::PathBuf;

use crate::components::files::file_preview::FilePreview;
use dioxus::prelude::*;
use kit::layout::modal::Modal;
use warp::constellation::file::File;

#[component(no_case_check)]
pub fn get_file_modal<'a>(
    cx: Scope<'a>,
    on_dismiss: EventHandler<'a, ()>,
    on_download: EventHandler<'a, Option<PathBuf>>,
    file: File,
) -> Element<'a> {
    cx.render(rsx!(Modal {
        onclose: move |_| on_dismiss.call(()),
        open: true,
        transparent: false,
        dont_pad: true,
        close_on_click_inside_modal: true,
        children: cx.render(rsx!(FilePreview {
            file: file,
            on_download: |temp_path| {
                on_download.call(temp_path);
            },
        }))
    }))
}
