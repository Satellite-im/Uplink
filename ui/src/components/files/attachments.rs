use std::path::PathBuf;

use common::{
    icons, language::get_local_text_args_builder, state::State, warp_runner::thumbnail_to_base64,
    MAX_FILES_PER_MESSAGE,
};
use dioxus::prelude::*;
use kit::components::embeds::file_embed::FileEmbed;
use uuid::Uuid;
use warp::raygun::Location;

#[derive(Props)]
pub struct AttachmentProps<'a> {
    pub chat_id: Uuid,
    pub files_to_attach: Vec<Location>,
    pub on_remove: EventHandler<Vec<Location>>,
}

#[allow(non_snake_case)]
pub fn Attachments<'a>(cx: Scope<'a, AttachmentProps>) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let files_attached_to_send = cx.props.files_to_attach.clone();
    let files_attached_to_send3 = files_attached_to_send;

    // todo: pick an icon based on the file extension
    let attachments = cx.render(rsx!(cx.props.files_to_attach.iter().map(|location| {
        let (filename, filepath, thumbnail) = match &location {
            Location::Constellation { path } => {
                let filename = PathBuf::from(&path)
                    .file_name()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .to_string();

                let warp_file = state
                    .read()
                    .storage
                    .files
                    .iter()
                    .find(|x| x.name() == filename)
                    .cloned();

                let thumbnail = match warp_file {
                    Some(f) => thumbnail_to_base64(&f),
                    None => String::new(),
                };

                (filename, PathBuf::from(&path), thumbnail)
            }
            Location::Disk { path } => (
                path.file_name()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .to_string(),
                path.clone(),
                String::new(),
            ),
        };

        rsx!(FileEmbed {
            filename: filename,
            filepath: filepath,
            remote: false,
            is_from_attachments: true,
            thumbnail: thumbnail,
            button_icon: icons::outline::Shape::Minus,
            on_press: move |pathbuf: Option<PathBuf>| {
                if pathbuf.is_none() {
                    let mut attachments = cx.props.files_to_attach.clone();
                    attachments.retain(|location2| location2 != location);
                    cx.props.on_remove.call(attachments);
                }
            },
        })
    })));

    let attachments_vec = files_attached_to_send3;

    if attachments_vec.is_empty() {
        return None;
    }

    cx.render(rsx!(div {
        id: "compose-attachments",
        aria_label: "compose-attachments",
            div {
                id: "attachments-error",
                if attachments_vec.len() >= MAX_FILES_PER_MESSAGE {
                    rsx!(p {
                        class: "error",
                        aria_label: "input-error",
                        margin_left: "var(--gap)",
                        margin_top: "var(--gap)",
                        margin_bottom: "var(--gap)",
                        color: "var(--warning-light)",
                        get_local_text_args_builder("messages.maximum-amount-files-per-message", |m| {
                            m.insert("amount", MAX_FILES_PER_MESSAGE.into());
                        })
                    })
                }
            attachments
            }
    }))
}
