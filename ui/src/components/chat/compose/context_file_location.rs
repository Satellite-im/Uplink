use common::{icons::outline::Shape as Icon, language::get_local_text, state::State};
use dioxus::prelude::*;
use kit::{
    components::context_menu::{ContextItem, ContextMenu},
    elements::tooltip::Tooltip,
};

#[derive(Props)]
pub struct FileLocationProps<'a> {
    id: &'a String,
    update_script: &'a UseState<String>,
    on_press_storage: EventHandler<'a, ()>,
    on_press_local_disk: EventHandler<'a, ()>,
}

#[allow(non_snake_case)]
pub fn FileLocationContext<'a>(cx: Scope<'a, FileLocationProps<'a>>) -> Element<'a> {
    let state = use_shared_state::<State>(cx)?;
    let id = cx.props.id.clone();
    let eval = use_eval(cx);
    use_future(cx, cx.props.update_script, |update_script| {
        to_owned![eval];
        async move {
            let script = update_script.get();
            if !script.is_empty() {
                let _ = eval(script.to_string().as_str());
            }
        }
    });

    let are_files_been_uploaded = !state.read().storage.files_in_queue_to_upload.is_empty();

    cx.render(rsx!(ContextMenu {
        id: format!("{id}"),
        items: cx.render(rsx!(
            ContextItem {
                icon: Icon::Plus,
                aria_label: "attach-files-from-local-disk-into-chat".into(),
                text: get_local_text("files.attach-files-from-local-disk"),
                onpress: move |_| {
                    cx.props.on_press_local_disk.call(());
                }
            },
            ContextItem {
                icon: Icon::FolderOpen,
                aria_label: "attach-files-from-storage-into-chat".into(),
                disabled: are_files_been_uploaded,
                text: get_local_text("files.attach-files-from-storage"),
                onpress: move |_| {
                    cx.props.on_press_storage.call(());
                },
                tooltip: if are_files_been_uploaded {
                    cx.render(rsx!(Tooltip {
                        arrow_position: kit::elements::tooltip::ArrowPosition::Right,
                        text: get_local_text("files.upload-in-progress-please-wait"),
                    }))
                } else {
                    None
                },
            }
        ))
    }))
}
