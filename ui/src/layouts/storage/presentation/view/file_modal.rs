use crate::components::files::file_preview::FilePreview;
use dioxus::prelude::*;
use dioxus_core::{prelude::EventHandler, Scope};
use kit::layout::modal::Modal;
use warp::constellation::file::File;

#[inline_props]
pub fn get_file_modal<'a>(
    cx: Scope<'a>,
    on_dismiss: EventHandler<'a, ()>,
    on_download: EventHandler<'a, ()>,
    file: File,
) -> Element<'a> {
    cx.render(rsx!(Modal {
        onclose: move |_| on_dismiss.call(()),
        children: cx.render(rsx!(FilePreview {
            file: file,
            on_download: |_| {
                on_download.call(());
            },
        }))
        open: true,
    }))
}
