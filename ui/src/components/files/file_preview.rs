use common::language::get_local_text;
use common::{icons::outline::Shape as Icon, warp_runner::thumbnail_to_base64};
use dioxus::prelude::*;
use kit::components::context_menu::{ContextItem, ContextMenu};
use warp::constellation::file::File;

use crate::utils::clipboard_data;

#[derive(Props)]
pub struct Props<'a> {
    file: &'a File,
    on_download: EventHandler<'a, ()>,
}

#[allow(non_snake_case)]
pub fn FilePreview<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let thumbnail = thumbnail_to_base64(cx.props.file);
    let image_from_clipboard = use_ref(cx, || String::new());

    cx.render(rsx!(div {
        ContextMenu {
            id: "file-preview-context-menu".into(),
            items: cx.render(rsx!(
                ContextItem {
                    icon: Icon::ArrowDownCircle,
                    aria_label: "files-download-preview".into(),
                    text: get_local_text("files.download"),
                    onpress: move |_| {
                        cx.props.on_download.call(());
                    }
                },
                ContextItem {
                    icon: Icon::ClipboardDocument,
                    aria_label: "files-download-preview".into(),
                    text: "Paste".to_owned(),
                    onpress: move |_| {
                       let test =  clipboard_data::paste_file_from_clipboard().unwrap_or_default();
                    //    image_from_clipboard.with_mut(|i| *i = test);
                    }
                },
            )),
            img {
                id: "file_preview_img",
                src: "{thumbnail}",
                position: "absolute",
                top: "50%",
                left: "50%",
                transform: "translate(-50%, -50%)",
                max_height: "80%",
                max_width: "80%",
            },
            img {
                id: "file_preview_img",
                src: format_args!("{}", image_from_clipboard.read()),
                position: "absolute",
                top: "50%",
                left: "50%",
                transform: "translate(-50%, -50%)",
                max_height: "80%",
                max_width: "80%",
            },
        },
    }))
}
