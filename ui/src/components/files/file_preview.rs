use common::language::get_local_text;
use common::state::State;
use common::{icons::outline::Shape as Icon, warp_runner::thumbnail_to_base64};
use dioxus::prelude::*;
use kit::components::context_menu::{ContextItem, ContextMenu};
use warp::constellation::file::File;

#[derive(Props)]
pub struct Props<'a> {
    file: &'a File,
    on_download: EventHandler<'a, ()>,
}

#[allow(non_snake_case)]
pub fn FilePreview<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let thumbnail = thumbnail_to_base64(cx.props.file);
    let state = use_shared_state::<State>(cx)?;

    cx.render(rsx!(
        ContextMenu {
            id: "file-preview-context-menu".into(),
            devmode: state.read().configuration.developer.developer_mode,
            items: cx.render(rsx!(
                ContextItem {
                    icon: Icon::ArrowDownCircle,
                    aria_label: "files-download-preview".into(),
                    text: get_local_text("files.download"),
                    onpress: move |_| {
                        cx.props.on_download.call(());
                    }
                },
            )),
            img {
                id: "file_preview_img",
                aria_label: "file-preview-image",
                src: "{thumbnail}",
            },
        },
    ))
}
