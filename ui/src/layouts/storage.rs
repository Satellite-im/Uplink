use std::time::Duration;
use std::{ffi::OsStr, path::PathBuf};

use common::icons::outline::Shape as Icon;
use common::icons::Icon as IconElement;
use common::language::get_local_text;
use common::warp_runner::{FileTransferProgress, FileTransferStep, ThumbnailType, DuplicateNameStep};
use common::{
    state::{storage::Storage, ui, Action, State},
    warp_runner::{ConstellationCmd, WarpCmd},
    WARP_CMD_CH,
};
use dioxus::{html::input_data::keyboard_types::Code, prelude::*};
use dioxus_desktop::{use_window};
use dioxus_router::*;
use futures::{channel::oneshot, StreamExt};
use kit::{
    components::{
        context_menu::{ContextItem, ContextMenu},
        nav::Nav,
    },
    elements::{
        button::Button,
        file::File,
        folder::Folder,
        tooltip::{ArrowPosition, Tooltip},
        Appearance,
    },
    layout::topbar::Topbar,
};
use once_cell::sync::Lazy;
use rfd::FileDialog;
use tokio::sync::mpsc;
use tokio::time::sleep;
use uuid::Uuid;
use warp::constellation::item::Item;
use warp::sync::RwLock;
use warp::{
    constellation::{directory::Directory, file::File},
    logging::tracing::log,
};
use wry::webview::FileDropEvent;

use crate::components::chat::{sidebar::Sidebar as ChatSidebar, RouteInfo};

const FEEDBACK_TEXT_SCRIPT: &str = r#"
    const feedback_element = document.getElementById('overlay-text');
    feedback_element.textContent = '$TEXT';
"#;

const FILE_NAME_SCRIPT: &str = r#"
    const filename = document.getElementById('overlay-text0');
    filename.textContent = '$FILE_NAME';
"#;

const ANIMATION_DASH_SCRIPT: &str = r#"
    var dashElement = document.getElementById('dash-element')
    dashElement.style.animation = "border-dance 0.5s infinite linear"
"#;

const MAX_LEN_TO_FORMAT_NAME: usize = 15;

pub const ROOT_DIR_NAME: &str = "root";

pub static DRAG_EVENT: Lazy<RwLock<FileDropEvent>> =
    Lazy::new(|| RwLock::new(FileDropEvent::Cancelled));

enum ChanCmd {
    GetItemsFromCurrentDirectory,
    CreateNewDirectory(String),
    OpenDirectory(String),
    BackToPreviousDirectory(Directory),
    UploadFiles(Vec<PathBuf>),
    DownloadFile {
        file_name: String,
        local_path_to_save_file: PathBuf,
    },
    RenameItem {
        old_name: String,
        new_name: String,
    },
    DeleteItems(Item),
}

#[derive(PartialEq, Props)]
pub struct Props {
    route_info: RouteInfo,
}

#[allow(non_snake_case)]
pub fn FilesLayout(cx: Scope<Props>) -> Element {
    let state = use_shared_state::<State>(cx)?;
    state.write_silent().ui.current_layout = ui::Layout::Storage;

    let free_space_text = get_local_text("files.free-space");
    let total_space_text = get_local_text("files.total-space");
    let storage_state: &UseState<Option<Storage>> = use_state(cx, || None);
    let current_dir = use_ref(cx, || state.read().storage.current_dir.clone());
    let directories_list = use_ref(cx, || state.read().storage.directories.clone());
    let files_list = use_ref(cx, || state.read().storage.files.clone());
    let dirs_opened_ref = use_ref(cx, || state.read().storage.directories_opened.clone());

    let add_new_folder = use_state(cx, || false);



    let drag_event: &UseRef<Option<FileDropEvent>> = use_ref(cx, || None);

    let main_script = include_str!("./storage.js");

    let window = use_window(cx);

    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<ChanCmd>| {
        to_owned![storage_state, main_script, window];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some(cmd) = rx.next().await {
                match cmd {
                    ChanCmd::CreateNewDirectory(directory_name) => {
                        let (tx, rx) = oneshot::channel::<Result<(), warp::error::Error>>();
                        let directory_name2 = directory_name.clone();

                        if let Err(e) = warp_cmd_tx.send(WarpCmd::Constellation(
                            ConstellationCmd::CreateNewDirectory {
                                directory_name,
                                rsp: tx,
                            },
                        )) {
                            log::error!("failed to add new directory {}", e);
                            continue;
                        }

                        let rsp = rx.await.expect("command canceled");

                        match rsp {
                            Ok(_) => {
                                log::info!("New directory added: {}", directory_name2);
                            }
                            Err(e) => {
                                log::error!("failed to add new directory: {}", e);
                                continue;
                            }
                        }
                    }
                    ChanCmd::GetItemsFromCurrentDirectory => {
                        let (tx, rx) = oneshot::channel::<Result<Storage, warp::error::Error>>();

                        if let Err(e) = warp_cmd_tx.send(WarpCmd::Constellation(
                            ConstellationCmd::GetItemsFromCurrentDirectory { rsp: tx },
                        )) {
                            log::error!("failed to get items from current directory {}", e);
                            continue;
                        }

                        let rsp = rx.await.expect("command canceled");
                        match rsp {
                            Ok(storage) => {
                                storage_state.set(Some(storage));
                            }
                            Err(e) => {
                                log::error!("failed to add new directory: {}", e);
                                continue;
                            }
                        }
                    }
                    ChanCmd::OpenDirectory(directory_name) => {
                        let (tx, rx) = oneshot::channel::<Result<Storage, warp::error::Error>>();
                        let directory_name2 = directory_name.clone();

                        if let Err(e) = warp_cmd_tx.send(WarpCmd::Constellation(
                            ConstellationCmd::OpenDirectory {
                                directory_name,
                                rsp: tx,
                            },
                        )) {
                            log::error!("failed to open {directory_name2} directory {}", e);
                            continue;
                        }

                        let rsp = rx.await.expect("command canceled");
                        match rsp {
                            Ok(storage) => {
                                storage_state.set(Some(storage));
                                log::info!("Folder {} opened", directory_name2);
                            }
                            Err(e) => {
                                log::error!("failed to open folder {directory_name2}: {}", e);
                                continue;
                            }
                        }
                    }
                    ChanCmd::BackToPreviousDirectory(directory) => {
                        let (tx, rx) = oneshot::channel::<Result<Storage, warp::error::Error>>();
                        let directory_name = directory.name();

                        if let Err(e) = warp_cmd_tx.send(WarpCmd::Constellation(
                            ConstellationCmd::BackToPreviousDirectory { directory, rsp: tx },
                        )) {
                            log::error!("failed to open directory {}: {}", directory_name, e);
                            continue;
                        }

                        let rsp = rx.await.expect("command canceled");
                        match rsp {
                            Ok(storage) => {
                                storage_state.set(Some(storage));
                                log::info!("Folder {} opened", directory_name);
                            }
                            Err(e) => {
                                log::error!("failed to open directory {}: {}", directory_name, e);
                                continue;
                            }
                        }
                    }
                    ChanCmd::UploadFiles(files_path) => {
                        let mut script = main_script.replace("$IS_DRAGGING", "true");
                        script.push_str(&ANIMATION_DASH_SCRIPT);
                        window.eval(&script);

                        let (tx, mut rx) = mpsc::unbounded_channel::<FileTransferProgress<Storage>>();

                        if let Err(e) = warp_cmd_tx.send(WarpCmd::Constellation(
                            ConstellationCmd::UploadFiles {
                                files_path,
                                rsp: tx,
                            },
                        )) {
                            log::error!("failed to upload files {}", e);
                            continue;
                        }
                        while let Some(msg) = rx.recv().await {
                            match msg {
                                FileTransferProgress::Step(steps) => {
                                    match steps {
                                        FileTransferStep::Start(name) => {
                                            let mut script = FEEDBACK_TEXT_SCRIPT.replace("$TEXT","Starting upload...");
                                            let file_name_formatted = format_item_name(name);
                                            script.push_str(&FILE_NAME_SCRIPT.replace("$FILE_NAME",&file_name_formatted));
                                            window.eval(&script);
                                            sleep(Duration::from_millis(100)).await;
                                        },
                                        FileTransferStep::DuplicateName(duplicate_name_step) => {
                                                match duplicate_name_step {
                                                    DuplicateNameStep::Start => {
                                                        let script = FEEDBACK_TEXT_SCRIPT.replace("$TEXT","Renaming if duplicated");
                                                        window.eval(&script);
                                                    },
                                                    DuplicateNameStep::Finished(name) => {
                                                        let file_name_formatted = format_item_name(name);
                                                        let script = FILE_NAME_SCRIPT.replace("$FILE_NAME",&file_name_formatted);
                                                        window.eval(&script);
                                                    },
                                                }
                                                sleep(Duration::from_millis(100)).await;
                                        },
                                        FileTransferStep::Upload(progress) => {
                                            if progress.contains("%") {
                                                let script = FEEDBACK_TEXT_SCRIPT.replace("$TEXT",&format!("{} {}", progress, "uploaded"));
                                                window.eval(&script);
                                            } else {
                                                let script = FEEDBACK_TEXT_SCRIPT.replace("$TEXT",&format!("{} {}", "Uploaded", progress));
                                                window.eval(&script);
                                            }
                                            sleep(Duration::from_millis(3)).await;

                                        },
                                        FileTransferStep::Thumbnail(thumb_type) => {
                                            match thumb_type {
                                                ThumbnailType::Image => {
                                                    let script = FEEDBACK_TEXT_SCRIPT.replace("$TEXT","Image thumb uploaded");
                                                    window.eval(&script);
                                                },
                                                ThumbnailType::Video => {
                                                    let script = FEEDBACK_TEXT_SCRIPT.replace("$TEXT","Video thumb uploaded");
                                                    window.eval(&script);
                                                },
                                                ThumbnailType::None => {
                                                    let script = FEEDBACK_TEXT_SCRIPT.replace("$TEXT","No thumb uploaded");
                                                    window.eval(&script);
                                                },
                                            }
                                            sleep(Duration::from_millis(100)).await;

                                        }
                                    };
                                }
                                FileTransferProgress::Finished(storage) => {
                                    let mut script = main_script.replace("$IS_DRAGGING", "false");
                                    script.push_str(&FEEDBACK_TEXT_SCRIPT.replace("$TEXT", ""));
                                    script.push_str(&FILE_NAME_SCRIPT.replace("$FILE_NAME", ""));
                                    script.push_str(&ANIMATION_DASH_SCRIPT.replace("0.5s", "0s"));
                                    window.eval(&script);
                                    storage_state.set(Some(storage));
                                    break;
                                }
                                FileTransferProgress::Error(_) => {
                                    let mut script = main_script.replace("$IS_DRAGGING", "false");
                                    script.push_str(&FEEDBACK_TEXT_SCRIPT.replace("$TEXT", ""));
                                    script.push_str(&FILE_NAME_SCRIPT.replace("$FILE_NAME", ""));
                                    script.push_str(&ANIMATION_DASH_SCRIPT.replace("0.5s", "0s"));
                                    window.eval(&script);
                                    break;
                                }
                            }
                        }
                    }
                    ChanCmd::DownloadFile {
                        file_name,
                        local_path_to_save_file,
                    } => {
                        let (tx, rx) = oneshot::channel::<Result<(), warp::error::Error>>();

                        if let Err(e) = warp_cmd_tx.send(WarpCmd::Constellation(
                            ConstellationCmd::DownloadFile {
                                file_name,
                                local_path_to_save_file,
                                rsp: tx,
                            },
                        )) {
                            log::error!("failed to download file {}", e);
                            continue;
                        }

                        let rsp = rx.await.expect("command canceled");

                        if let Err(error) = rsp {
                            log::error!("failed to download file: {}", error);
                            continue;
                        }
                    }
                    ChanCmd::RenameItem { old_name, new_name } => {
                        let (tx, rx) = oneshot::channel::<Result<Storage, warp::error::Error>>();

                        if let Err(e) =
                            warp_cmd_tx.send(WarpCmd::Constellation(ConstellationCmd::RenameItem {
                                old_name,
                                new_name,
                                rsp: tx,
                            }))
                        {
                            log::error!("failed to rename item {}", e);
                            continue;
                        }

                        let rsp = rx.await.expect("command canceled");
                        match rsp {
                            Ok(storage) => {
                                storage_state.set(Some(storage));
                            }
                            Err(e) => {
                                log::error!(
                                    "failed to update uplink storage with renamed item: {}",
                                    e
                                );
                                continue;
                            }
                        }
                    }
                    ChanCmd::DeleteItems(item) => {
                        let (tx, rx) = oneshot::channel::<Result<Storage, warp::error::Error>>();

                        if let Err(e) = warp_cmd_tx.send(WarpCmd::Constellation(
                            ConstellationCmd::DeleteItems {
                                item: item.clone(),
                                rsp: tx,
                            },
                        )) {
                            log::error!("failed to delete items {}, item {:?}", e, item.name());
                            continue;
                        }

                        let rsp = rx.await.expect("command canceled");
                        match rsp {
                            Ok(storage) => {
                                storage_state.set(Some(storage));
                            }
                            Err(e) => {
                                log::error!("failed to delete items {}, item {:?}", e, item.name());
                                continue;
                            }
                        }
                    }
                }
            }
        }
    });

    let is_renaming_map: &UseRef<Option<Uuid>> = use_ref(cx, || None);

    let first_render = use_state(cx, || true);
    if *first_render.get() && state.read().ui.is_minimal_view() {
        state.write().mutate(Action::SidebarHidden(true));
        first_render.set(false);
    }

    if let Some(storage) = storage_state.get().clone() {
        state.write().storage = storage.clone();
        *directories_list.write_silent() = storage.directories.clone();
        *files_list.write_silent() = storage.files.clone();
        *current_dir.write_silent() = storage.current_dir.clone();
        *dirs_opened_ref.write_silent() = storage.directories_opened.clone();
        storage_state.set(None);
    }


    use_future(cx, (), |_| {
            to_owned![ch, directories_list, files_list];
            async move {
                loop {
                    if !directories_list.read().is_empty() || !files_list.read().is_empty() {
                        break;
                    }
                    sleep(Duration::from_millis(1000)).await;
                    ch.send(ChanCmd::GetItemsFromCurrentDirectory);
                    println!("Looping");
                }
            }
    });

    cx.render(rsx!(
        div {
            id: "overlay-element",
            class: "overlay-element",
            div {id: "dash-element", class: "dash-background active-animation"},
            p {id: "overlay-text0", class: "overlay-text"},
            p {id: "overlay-text", class: "overlay-text"}
        },
        div {
            id: "files-layout",
            aria_label: "files-layout",
            ondragover: move |_| {
                if let None = drag_event.read().clone() {
                    let window = use_window(cx);
                    cx.spawn({
                        to_owned![drag_event, window, ch, main_script];
                        async move {
                            loop {
                                let file_drop_event = get_drag_event();
                                *drag_event.write_silent() = Some(file_drop_event.clone());
                                match file_drop_event {
                                    FileDropEvent::Hovered(files_local_path) => {
                                        let mut script = main_script.replace("$IS_DRAGGING", "true");
                                        script.push_str(&FEEDBACK_TEXT_SCRIPT.replace("$TEXT", &format!("{} files to upload!", files_local_path.len())));
                                        window.eval(&script);
                                    }
                                    FileDropEvent::Dropped(files_local_path) => {
                                        ch.send(ChanCmd::UploadFiles(files_local_path.clone()));
                                        break;
                                    }
                                    _ => {
                                        let script = main_script.replace("$IS_DRAGGING", "false");
                                        window.eval(&script);
                                        break;
                                    }
                                };
                                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                            };
                            *drag_event.write_silent() = None;
                        }
                    });
                };               
                },
            onclick: |_| is_renaming_map.with_mut(|i| *i = None),
            ChatSidebar {
                route_info: cx.props.route_info.clone()
            },
            div {
                class: "files-body",
                aria_label: "files-body",
                Topbar {
                    with_back_button: state.read().ui.is_minimal_view() || state.read().ui.sidebar_hidden,
                    with_currently_back: state.read().ui.sidebar_hidden,
                    onback: move |_| {
                        let current = state.read().ui.sidebar_hidden;
                        state.write().mutate(Action::SidebarHidden(!current));
                    },
                    controls: cx.render(
                        rsx! (
                            Button {
                                icon: Icon::FolderPlus,
                                appearance: Appearance::Secondary,
                                aria_label: "add-folder".into(),
                                tooltip: cx.render(rsx!(
                                    Tooltip {
                                        arrow_position: ArrowPosition::Top,
                                        text: get_local_text("files.new-folder"),
                                    }
                                )),
                                onpress: move |_| {
                                    is_renaming_map.with_mut(|i| *i = None);
                                    add_new_folder.set(!add_new_folder);
                                },
                            },
                            Button {
                                icon: Icon::Plus,
                                appearance: Appearance::Secondary,
                                aria_label: "upload-file".into(),
                                tooltip: cx.render(rsx!(
                                    Tooltip {
                                        arrow_position: ArrowPosition::Top,
                                        text: get_local_text("files.upload"),
                                    }
                                ))
                                onpress: move |_| {
                                    is_renaming_map.with_mut(|i| *i = None);
                                    let files_local_path = match FileDialog::new().set_directory(".").pick_files() {
                                        Some(path) => path,
                                        None => return
                                    };
                                    ch.send(ChanCmd::UploadFiles(files_local_path));
                                    cx.needs_update();
                                },
                            }
                        )
                    ),
                    div {
                        class: "files-info",
                        aria_label: "files-info",
                        p {
                            class: "free-space",
                            "{free_space_text}",
                            span {
                                class: "count",
                                "0MB"
                            }
                        },
                        p {
                            class: "total-space",
                            "{total_space_text}",
                            span {
                                class: "count",
                                "10MB"
                            }
                        }
                    }
                }
                div {
                    class: "files-bar-track",
                    div {
                        class: "files-bar",
                    }
                },
                div {
                    class: "files-breadcrumbs",
                    aria_label: "files-breadcrumbs",
                    dirs_opened_ref.read().iter().enumerate().map(|(index, dir)| {
                        let directory = dir.clone();
                        let dir_name = dir.name();
                        if dir_name == ROOT_DIR_NAME && index == 0 {
                            let home_text = get_local_text("uplink.home");
                            rsx!(div {
                                class: "crumb",
                                aria_label: "crumb",
                                onclick: move |_| {
                                    ch.send(ChanCmd::BackToPreviousDirectory(directory.clone()));
                                },
                                IconElement {
                                    icon: Icon::Home,
                                },
                                p {
                                    "{home_text}",
                                }
                            })
                        } else {
                            let folder_name_formated = format_item_name(dir_name);
                            rsx!(div {
                                class: "crumb",
                                onclick: move |_| {
                                    ch.send(ChanCmd::BackToPreviousDirectory(directory.clone()));
                                },
                                aria_label: "crumb",
                                p {
                                    "{folder_name_formated}"
                                }
                            },)
                        }
                    })
                },
                span {
                    class: "file-parent",
                    div {
                        class: "files-list",
                        aria_label: "files-list",
                        add_new_folder.then(|| {
                            rsx!(
                            Folder {
                                with_rename: true,
                                onrename: |(val, key_code)| {
                                    let new_name: String = val;
                                    if key_code == Code::Enter {
                                        ch.send(ChanCmd::CreateNewDirectory(new_name));
                                        ch.send(ChanCmd::GetItemsFromCurrentDirectory);
                                    }
                                    add_new_folder.set(false);
                                 }
                            })
                        }),
                        directories_list.read().iter().map(|dir| {
                            let folder_name = dir.name();
                            let folder_name2 = dir.name();
                            let key = dir.id();
                            let dir2 = dir.clone();
                            rsx!(
                                ContextMenu {
                                    key: "{key}-menu",
                                    id: dir.id().to_string(),
                                    items: cx.render(rsx!(
                                        ContextItem {
                                            icon: Icon::Pencil,
                                            text: get_local_text("files.rename"),
                                            onpress: move |_| {
                                                is_renaming_map.with_mut(|i| *i = Some(key));
                                            }
                                        },
                                        hr {},
                                        ContextItem {
                                            icon: Icon::Trash,
                                            danger: true,
                                            text: get_local_text("uplink.delete"),
                                            onpress: move |_| {
                                                let item = Item::from(dir2.clone());
                                                ch.send(ChanCmd::DeleteItems(item));
                                            }
                                        },
                                    )),
                                Folder {
                                    key: "{key}-folder",
                                    text: dir.name(),
                                    aria_label: dir.name(),
                                    with_rename: *is_renaming_map.read() == Some(key),
                                    onrename: move |(val, key_code)| {
                                        is_renaming_map.with_mut(|i| *i = None);
                                        if key_code == Code::Enter {
                                            ch.send(ChanCmd::RenameItem{old_name: folder_name2.clone(), new_name: val});
                                        }
                                    }
                                    onpress: move |_| {
                                        is_renaming_map.with_mut(|i| *i = None);
                                        ch.send(ChanCmd::OpenDirectory(folder_name.clone()));
                                    }
                            }})
                        }),
                       files_list.read().iter().map(|file| {
                            let file_name = file.name();
                            let file_name2 = file.name();
                            let file2 = file.clone();
                            let key = file.id();
                            rsx!(ContextMenu {
                                        key: "{key}-menu",
                                        id: file.id().to_string(),
                                        items: cx.render(rsx!(
                                            ContextItem {
                                                icon: Icon::Pencil,
                                                text: get_local_text("files.rename"),
                                                onpress: move |_| {
                                                    is_renaming_map.with_mut(|i| *i = Some(key));
                                                }
                                            },
                                            ContextItem {
                                                icon: Icon::ArrowDownCircle,
                                                text: get_local_text("files.download"),
                                                onpress: move |_| {
                                                    let file_extension = std::path::Path::new(&file_name2)
                                                        .extension()
                                                        .and_then(OsStr::to_str)
                                                        .map(|s| s.to_string())
                                                        .unwrap_or_default();
    
                                                    let file_stem = PathBuf::from(&file_name2)
                                                            .file_stem()
                                                            .and_then(OsStr::to_str)
                                                            .map(str::to_string)
                                                            .unwrap_or_default();
    
                                                    let file_path_buf = match FileDialog::new().set_directory(".").set_file_name(&file_stem).add_filter("", &[&file_extension]).save_file() {
                                                        Some(path) => path,
                                                        None => return,
                                                    };
                                                    ch.send(ChanCmd::DownloadFile { file_name: file_name2.clone(), local_path_to_save_file: file_path_buf } );
                                                },
                                            },
                                            hr {},
                                            ContextItem {
                                                icon: Icon::Trash,
                                                danger: true,
                                                text: get_local_text("uplink.delete"),
                                                onpress: move |_| {
                                                    let item = Item::from(file2.clone());
                                                    ch.send(ChanCmd::DeleteItems(item));
                                                }
                                            },
                                        )),
                                        File {
                                            key: "{key}-file",
                                            thumbnail: file.thumbnail(),
                                            text: file.name(),
                                            aria_label: file.name(),
                                            with_rename: *is_renaming_map.read() == Some(key),
                                            onrename: move |(val, key_code)| {
                                                is_renaming_map.with_mut(|i| *i = None);
                                                if key_code == Code::Enter {
                                                    ch.send(ChanCmd::RenameItem{old_name: file_name.clone(), new_name: val});
                                                }
                                            }
                                        }
                                    }
                              )
                        }),
                    },
                }

                (state.read().ui.sidebar_hidden && state.read().ui.metadata.minimal_view).then(|| rsx!(
                    Nav {
                        routes: cx.props.route_info.routes.clone(),
                        active: cx.props.route_info.active.clone(),
                        onnavigate: move |r| {
                            use_router(cx).replace_route(r, None, None);
                        }
                    }
                ))
            }
        }
    ))
}

fn get_drag_event() -> FileDropEvent {
    DRAG_EVENT.read().clone()
}

fn format_item_name(file_name: String) -> String {
    let mut file_name_formatted = file_name.clone();
    let item = PathBuf::from(&file_name);

    let file_stem = item
        .file_stem()
        .and_then(OsStr::to_str)
        .map(str::to_string)
        .unwrap_or_default();

    if file_stem.len() > MAX_LEN_TO_FORMAT_NAME {
        file_name_formatted = match &file_name.get(0..15) {
            Some(name_sliced) => format!(
                "{}...",
                name_sliced,
            ),
            None => file_name.clone(),
        };
    }
    file_name_formatted
}