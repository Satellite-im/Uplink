use std::path::PathBuf;

use common::{icons, language::get_local_text_args_builder, MAX_FILES_PER_MESSAGE};
use dioxus::prelude::*;
use kit::components::embeds::file_embed::FileEmbed;
use uuid::Uuid;
use warp::raygun::Location;

#[derive(Props)]
pub struct AttachmentProps<'a> {
    pub chat_id: Uuid,
    pub files_to_attach: Vec<Location>,
    pub on_remove: EventHandler<'a, Vec<Location>>,
}

#[allow(non_snake_case)]
pub fn Attachments<'a>(cx: Scope<'a, AttachmentProps>) -> Element<'a> {
    let files_attached_to_send = cx.props.files_to_attach.clone();
    let files_attached_to_send2 = files_attached_to_send.clone();
    let files_attached_to_send3 = files_attached_to_send;

    // todo: pick an icon based on the file extension
    let attachments = cx.render(rsx!(files_attached_to_send2.iter().map(|location| {
        let path = match location {
            Location::Constellation { path } => PathBuf::from(path),
            Location::Disk { path } => path.clone(),
        };

        let filename = path
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .to_string();

        rsx!(FileEmbed {
            filename: filename.clone(),
            filepath: match location {
                Location::Constellation { path } => PathBuf::from(&path),
                Location::Disk { path } => path.clone(),
            },
            remote: false,
            button_icon: icons::outline::Shape::Minus,
            on_press: move |_| {
                let mut attachments = cx.props.files_to_attach.clone();
                attachments.retain(|location| {
                    let path_to_retain = match location {
                        Location::Constellation { path } => PathBuf::from(path),
                        Location::Disk { path } => path.clone(),
                    };
                    path_to_retain != path
                });
                cx.props.on_remove.call(attachments);
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
