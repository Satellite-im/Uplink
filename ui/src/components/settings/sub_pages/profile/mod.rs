use std::path::PathBuf;

use arboard::Clipboard;
use common::get_images_dir;
use common::icons::Icon as IconElement;
use common::language::get_local_text;
use common::state::{Action, Identity, State, ToastNotification};
use common::warp_runner::{MultiPassCmd, TesseractCmd, WarpCmd};
use common::{icons::outline::Shape as Icon, WARP_CMD_CH};
use dioxus::prelude::*;
use dioxus_html::input_data::keyboard_types::Modifiers;
use futures::channel::oneshot;
use futures::StreamExt;
use kit::components::context_menu::{ContextItem, ContextMenu};
use kit::components::indicator::{Indicator, Platform, Status};
use kit::elements::checkbox::Checkbox;
use kit::elements::select::FancySelect;
use kit::elements::tooltip::Tooltip;
use kit::elements::Appearance;
use kit::elements::{
    button::Button,
    input::{Input, Options, Validation},
    label::Label,
};
use kit::layout::modal::Modal;
use mime::*;
use rfd::FileDialog;
use warp::multipass::identity::IdentityStatus;
use warp::{error::Error, logging::tracing::log};

use crate::components::crop_image_tool::circle_format_tool::CropCircleImageModal;
use crate::components::crop_image_tool::rectangle_format_tool::CropRectImageModal;
use crate::components::settings::{SettingSection, SettingSectionSimple};

#[derive(Clone)]
enum ChanCmd {
    Profile(Vec<u8>),
    ClearProfile,
    Banner(Vec<u8>),
    ClearBanner,
    Username(String),
    StatusMessage(String),
    Status(IdentityStatus),
}

#[allow(non_snake_case)]
pub fn ProfileSettings(cx: Scope) -> Element {
    log::trace!("rendering ProfileSettings");
    let state = use_shared_state::<State>(cx)?;
    let identity = state.read().get_own_identity();
    let user_status = identity.status_message().unwrap_or_default();
    let online_status = identity.identity_status();
    let identity_status_values = [
        IdentityStatus::Online,
        IdentityStatus::Away,
        IdentityStatus::Busy,
        IdentityStatus::Offline,
    ];
    let username = identity.username();
    let should_update: &UseState<Option<Identity>> = use_state(cx, || None);
    let update_failed: &UseState<Option<String>> = use_state(cx, || None);
    // TODO: This needs to persist across restarts but a config option seems overkill. Should we have another kind of file to cache flags?
    let image = identity.profile_picture();
    let banner = identity.profile_banner();
    let open_crop_image_modal = use_state(cx, || (false, (Vec::new(), String::new())));
    let open_crop_image_modal_for_banner_picture =
        use_state(cx, || (false, (Vec::new(), String::new())));

    //TODO: Remove `\0` as that should not be used to determined if an image is empty
    let no_profile_picture =
        image.eq("\0") || image.is_empty() || identity.contains_default_picture();
    let no_banner_picture = banner.eq("\0") || banner.is_empty();

    let seed_phrase: &UseState<Option<String>> = use_state(cx, || None);
    let seed_words_ch: &Coroutine<()> = use_coroutine(cx, |mut rx: UnboundedReceiver<()>| {
        to_owned![seed_phrase];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while rx.next().await.is_some() {
                // only one command so far
                let (tx, rx) = oneshot::channel();
                if let Err(e) =
                    warp_cmd_tx.send(WarpCmd::Tesseract(TesseractCmd::GetMnemonic { rsp: tx }))
                {
                    log::error!("error sending warp command: {e}");
                    continue;
                }

                let res = match rx.await {
                    Ok(r) => r,
                    Err(e) => {
                        log::error!("error receiving warp command: {e}");
                        continue;
                    }
                };

                match res {
                    Ok(seed_words) => {
                        seed_phrase.set(Some(seed_words));
                    }
                    Err(e) => {
                        log::error!("failed to get seed words: {e}");
                        continue;
                    }
                }
            }
        }
    });

    let remove_seed_words_ch = use_coroutine(cx, |mut rx: UnboundedReceiver<()>| {
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while rx.next().await.is_some() {
                // only one command so far
                let (tx, rx) = oneshot::channel();
                if let Err(e) =
                    warp_cmd_tx.send(WarpCmd::Tesseract(TesseractCmd::DeleteMnemonic { rsp: tx }))
                {
                    log::error!("error sending warp command: {e}");
                    continue;
                }

                let res = match rx.await {
                    Ok(r) => r,
                    Err(e) => {
                        log::error!("error receiving warp command: {e}");
                        continue;
                    }
                };

                match res {
                    Ok(_) => {
                        println!("Removed seed phrase");
                    }
                    Err(e) => {
                        log::error!("failed to remove seed words: {e}");
                        continue;
                    }
                }
            }
        }
    });

    let phrase_exists: &UseState<bool> = use_state(cx, || false);
    let seed_phrase_exists = use_coroutine(cx, |mut rx: UnboundedReceiver<()>| {
        to_owned![phrase_exists];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while rx.next().await.is_some() {
                // only one command so far
                let (tx, rx) = oneshot::channel();
                if let Err(e) =
                    warp_cmd_tx.send(WarpCmd::Tesseract(TesseractCmd::CheckMnemonicExist {
                        rsp: tx,
                    }))
                {
                    log::error!("error sending warp command: {e}");
                    continue;
                }

                let res = match rx.await {
                    Ok(r) => r,
                    Err(e) => {
                        log::error!("error receiving warp command: {e}");
                        continue;
                    }
                };

                match res {
                    Ok(does_exist) => {
                        phrase_exists.set(does_exist);
                    }
                    Err(e) => {
                        log::error!("failed to check for seed words: {e}");
                        continue;
                    }
                }
            }
        }
    });

    seed_phrase_exists.send(());

    if let Some(ident) = should_update.get() {
        log::trace!("Updating ProfileSettings");
        state.write().set_own_identity(ident.clone());
        state
            .write()
            .mutate(common::state::Action::AddToastNotification(
                ToastNotification::init(
                    "".into(),
                    get_local_text("settings-profile.updated"),
                    None,
                    2,
                ),
            ));
        should_update.set(None);
    }

    if let Some(msg) = update_failed.get() {
        state
            .write()
            .mutate(common::state::Action::AddToastNotification(
                ToastNotification::init(
                    get_local_text("warning-messages.error"),
                    msg.into(),
                    Some(common::icons::outline::Shape::ExclamationTriangle),
                    2,
                ),
            ));
        update_failed.set(None);
    }

    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<ChanCmd>| {
        to_owned![should_update, update_failed];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some(cmd) = rx.next().await {
                // this is lazy but I can get away with it for now
                let (tx, rx) = oneshot::channel();
                let warp_cmd = match cmd {
                    ChanCmd::Profile(pfp) => MultiPassCmd::UpdateProfilePicture { pfp, rsp: tx },
                    ChanCmd::ClearProfile => MultiPassCmd::ClearProfilePicture { rsp: tx },
                    ChanCmd::Banner(banner) => MultiPassCmd::UpdateBanner { banner, rsp: tx },
                    ChanCmd::ClearBanner => MultiPassCmd::ClearBanner { rsp: tx },
                    ChanCmd::Username(username) => {
                        MultiPassCmd::UpdateUsername { username, rsp: tx }
                    }
                    ChanCmd::StatusMessage(status) => MultiPassCmd::UpdateStatusMessage {
                        status: if status.is_empty() {
                            None
                        } else {
                            Some(status)
                        },
                        rsp: tx,
                    },
                    ChanCmd::Status(status) => MultiPassCmd::SetStatus { status, rsp: tx },
                };

                if let Err(e) = warp_cmd_tx.send(WarpCmd::MultiPass(warp_cmd)) {
                    log::error!("failed to send warp command: {}", e);
                    continue;
                }

                let res = rx.await.expect("command canceled");
                match res {
                    Ok(ident) => {
                        should_update.set(Some(ident));
                    }
                    Err(e) => {
                        let msg = match e {
                            warp::error::Error::InvalidLength { .. } => {
                                get_local_text("settings-profile.too-large")
                            }
                            _ => get_local_text("settings-profile.failed"),
                        };
                        update_failed.set(Some(msg));
                    }
                }
            }
        }
    });

    // Set up validation options for the input field
    let username_validation_options = Validation {
        // The input should have a maximum length of 32
        max_length: Some(32),
        // The input should have a minimum length of 4
        min_length: Some(4),
        // The input should only contain alphanumeric characters
        alpha_numeric_only: true,
        // The input should not contain any whitespace
        no_whitespace: true,
        // The input component validation is shared - if you need to allow just colons in, set this to true
        ignore_colons: false,
        // The input should allow any special characters
        // if you need special chars, just pass a vec! with each char necessary, mainly if alpha_numeric_only is true
        special_chars: None,
    };

    let status_validation_options = Validation {
        // The input should have a maximum length of 128
        max_length: Some(128),
        // The input should have a minimum length of 0
        min_length: Some(0),
        // The input should only contain alphanumeric characters
        alpha_numeric_only: false,
        // The input should not contain any whitespace
        no_whitespace: false,
        // The input component validation is shared - if you need to allow just colons in, set this to true
        ignore_colons: false,
        // The input should allow any special characters
        // if you need special chars, select action to allow or block and pass a vec! with each char necessary, mainly if alpha_numeric_only is true
        special_chars: None,
    };

    let did_short = identity.short_id().to_string();
    let did_key = identity.did_key();
    let short_name = format!("{}#{}", username, did_short);
    let short_name_context = short_name.clone();

    let show_welcome = &state.read().ui.active_welcome;

    let image_path = get_images_dir()
        .unwrap_or_default()
        .join("mascot")
        .join("working.webp")
        .to_str()
        .map(|x| x.to_string())
        .unwrap_or_default();

    let change_banner_text = get_local_text("settings-profile.change-banner");

    let store_phrase = use_state(cx, || true);

    let show_remove_seed = use_state(cx, || false);

    cx.render(rsx!(
        div {
            id: "settings-profile",
            class: "disable-select",
            aria_label: "settings-profile",
            (!show_welcome).then(|| rsx!(
                div {
                    class: "new-profile-welcome",
                    aria_label: "new-profile-welcome",
                    div {
                        class: "welcome",
                        img {
                            src: "{image_path}"
                        },
                    },
                    div {
                        class: "welcome-content",
                        Button {
                            text: get_local_text("uplink.dismiss"),
                            aria_label: "welcome-message-dismiss".into(),
                            icon: Icon::XMark,
                            onpress: move |_| {
                                state.write().ui.settings_welcome();
                                let _ = state.write().save();
                            }
                        },
                        Label {
                            aria_label: "welcome-message".into(),
                            text: get_local_text("settings-profile.welcome")
                        },
                        p {
                            aria_label: "welcome-message-desc",
                            get_local_text("settings-profile.welcome-desc")
                        }
                        br {},
                        p {
                            aria_label: "welcome-message-cta",
                            get_local_text("settings-profile.welcome-cta")
                        }
                    }
                },
            )),
            div {
                class: "profile-header",
                aria_label: "profile-header",
                // todo: when I wrap the profile-banner div in a ContextMenu, the onlick and oncontext events stop happening. not sure why.
                // ideally this ContextItem would appear when right clicking the profile-banner div.
                ContextMenu {
                    id: String::from("profile-banner-context-menu"),
                    items: cx.render(rsx!(
                        ContextItem {
                            icon: Icon::Trash,
                            disabled: no_banner_picture,
                            text: get_local_text("settings-profile.clear-banner"),
                            aria_label: "clear-banner".into(),
                            onpress: move |_| {
                                ch.send(ChanCmd::ClearBanner);
                            }
                        }
                    )),
                    div {
                        class: "profile-banner",
                        aria_label: "profile-banner",
                        style: "background-image: url({banner});",
                        onclick: move |mouse_event_data| {
                            if mouse_event_data.modifiers() != Modifiers::CONTROL {
                                set_banner(open_crop_image_modal_for_banner_picture.clone());
                            }
                        },
                        p {class: "change-banner-text", "{change_banner_text}" },
                    },
                },
                ContextMenu {
                    id: String::from("profile-picture-context-menu"),
                    items: cx.render(rsx!(
                        ContextItem {
                            icon: Icon::Trash,
                            disabled: no_profile_picture,
                            aria_label: "clear-avatar".into(),
                            text: get_local_text("settings-profile.clear-avatar"),
                            onpress: move |_| {
                                ch.send(ChanCmd::ClearProfile);
                            }
                        }
                    )),
                    div {
                        class: "profile-picture",
                        aria_label: "profile-picture",
                        style: "background-image: url({image});",
                        onclick: move |mouse_event_data: Event<MouseData>| {
                            if mouse_event_data.modifiers() != Modifiers::CONTROL {
                                set_profile_picture(open_crop_image_modal.clone());
                            }
                        },
                        Button {
                            icon: Icon::Plus,
                            aria_label: "add-picture-button".into(),
                            onpress: move |_| {
                            set_profile_picture(open_crop_image_modal.clone());
                            }
                        },
                    },
                }
            },
            div{
                class: "profile-content",
                aria_label: "profile-content",
                div {
                    class: "content-item",
                    Label {
                        text: get_local_text("uplink.username"),
                        aria_label: "profile-username-label".into(),
                    },
                    div {
                        class: "profile-group-username",
                        Input {
                            placeholder:  get_local_text("uplink.username"),
                            default_text: username.clone(),
                            aria_label: "username-input".into(),
                            options: Options {
                                with_clear_btn: true,
                                ..get_input_options(username_validation_options)
                            },
                            onreturn: move |(v, is_valid, _): (String, bool, _)| {
                                if !is_valid {
                                    return;
                                }
                                if v != username {
                                    ch.send(ChanCmd::Username(v));
                                }
                            },
                        },
                        div {
                            class: "profile-id-btn",
                            ContextMenu {
                                id: String::from("copy-id-context-menu"),
                                items: cx.render(rsx!(
                                    ContextItem {
                                        icon: Icon::UserCircle,
                                        text: get_local_text("settings-profile.copy-id"),
                                        aria_label: "copy-id-context".into(),
                                        onpress: move |_| {
                                            match Clipboard::new() {
                                                Ok(mut c) => {
                                                    if let Err(e) = c.set_text(short_name_context.clone()) {
                                                        log::warn!("Unable to set text to clipboard: {e}");
                                                    }
                                                },
                                                Err(e) => {
                                                    log::warn!("Unable to create clipboard reference: {e}");
                                                }
                                            };
                                            state
                                                .write()
                                                .mutate(Action::AddToastNotification(ToastNotification::init(
                                                    "".into(),
                                                    get_local_text("friends.copied-did"),
                                                    None,
                                                    2,
                                                )));
                                        }
                                    }
                                    ContextItem {
                                        icon: Icon::Key,
                                        text: get_local_text("settings-profile.copy-did"),
                                        aria_label: "copy-id-context".into(),
                                        onpress: move |_| {
                                            match Clipboard::new() {
                                                Ok(mut c) => {
                                                    if let Err(e) = c.set_text(did_key.to_string()) {
                                                        log::warn!("Unable to set text to clipboard: {e}");
                                                    }
                                                },
                                                Err(e) => {
                                                    log::warn!("Unable to create clipboard reference: {e}");
                                                }
                                            };
                                            state
                                                .write()
                                                .mutate(Action::AddToastNotification(ToastNotification::init(
                                                    "".into(),
                                                    get_local_text("friends.copied-did"),
                                                    None,
                                                    2,
                                                )));
                                        }
                                    }
                                )),
                                Button {
                                    appearance: Appearance::SecondaryLess,
                                    aria_label: "copy-id-button".into(),
                                    text: did_short.to_string(),
                                    tooltip: cx.render(rsx!(
                                        Tooltip{
                                            text: get_local_text("settings-profile.copy-id")
                                        }
                                    )),
                                    onpress: move |mouse_event: MouseEvent| {
                                        if mouse_event.modifiers() != Modifiers::CONTROL {
                                            match Clipboard::new() {
                                                Ok(mut c) => {
                                                    if let Err(e) = c.set_text(short_name.clone()) {
                                                        log::warn!("Unable to set text to clipboard: {e}");
                                                    }
                                                },
                                                Err(e) => {
                                                    log::warn!("Unable to create clipboard reference: {e}");
                                                }
                                            };
                                            state
                                                .write()
                                                .mutate(Action::AddToastNotification(ToastNotification::init(
                                                    "".into(),
                                                    get_local_text("friends.copied-did"),
                                                    None,
                                                    2,
                                                )));
                                        }
                                    }
                                }
                            },
                        }
                    },
                },
                div {
                    class: "content-item",
                    Label {
                        text: get_local_text("uplink.status"),
                        aria_label: "profile-status-label".into(),
                    },
                    Input {
                        placeholder: get_local_text("uplink.status"),
                        default_text: user_status.clone(),
                        aria_label: "status-input".into(),
                        options: Options {
                            with_clear_btn: true,
                            ..get_input_options(status_validation_options)
                        },
                        onreturn: move |(v, is_valid, _): (String, bool, _)| {
                            if !is_valid {
                                return;
                            }
                            if v != user_status {
                                ch.send(ChanCmd::StatusMessage(v));
                            }
                        },
                    }
                },
                SettingSection {
                    section_label: get_local_text("settings-profile.online-status"),
                    section_description: get_local_text("settings-profile.online-status-description"),
                    FancySelect {
                        initial_value: get_status_option(cx, &online_status),
                        width: 190,
                        options: identity_status_values.iter().map(|status| get_status_option(cx, status)).collect(),
                        onselect: move |value: String| {
                            let status = serde_json::from_str::<IdentityStatus>(&value).unwrap_or(IdentityStatus::Online);
                            ch.send(ChanCmd::Status(status));
                        }
                    },
                },
                if *phrase_exists.get() {rsx!(
                    SettingSection {
                        section_label: get_local_text("settings-profile.recovery-seed"),
                        section_description: get_local_text("settings-profile.recovery-seed-description"),
                        Button {
                            text: if seed_phrase.as_ref().is_none() { get_local_text("settings-profile.reveal-recovery-seed") } else { get_local_text("settings-profile.hide-recovery-seed") },
                            aria_label: "reveal-recovery-seed-button".into(),
                            appearance: Appearance::Danger,
                            icon: if seed_phrase.as_ref().is_none() { Icon::Eye } else { Icon::EyeSlash },
                            onpress: move |_| {
                                if seed_phrase.is_some() {
                                    seed_phrase.set(None);
                                } else {
                                    seed_words_ch.send(());
                                }
                            }
                        }
                    }
                    if let Some(phrase) = seed_phrase.as_ref() {
                        let words = phrase.split_whitespace().collect::<Vec<&str>>();
                        render!(
                            SettingSectionSimple {
                                div {
                                    class: "seed-words",
                                    words.chunks_exact(2).enumerate().map(|(idx, vals)| rsx! {
                                        div {
                                            class: "row",
                                            div {
                                                class: "col",
                                                span { class: "num", ((idx * 2) + 1).to_string() },
                                                span { class: "val", vals.first().cloned().unwrap_or_default() }
                                            },
                                            div {
                                                class: "col",
                                                span { class: "num", ((idx * 2) + 2).to_string() },
                                                span { class: "val", vals.get(1).cloned().unwrap_or_default() }
                                            }
                                        }
                                    })
                                }
                            }
                        )
                    },
                    SettingSectionSimple {
                        Checkbox {
                            disabled: false,
                            is_checked: *store_phrase.get(),
                            height: "15px".into(),
                            width: "15px".into(),
                            on_click: move |_| {
                                show_remove_seed.set(true);
                            },
                        },
                        label {
                            get_local_text("settings-profile.store-on-account")
                        }
                    },
                    show_remove_seed.then(|| rsx!(
                        Modal {
                            open: *show_remove_seed.clone(),
                            onclose: move |_| show_remove_seed.set(false),
                            transparent: false,
                            close_on_click_inside_modal: false,
                            div {
                                class: "remove-phrase-container",
                                div {
                                    class: "warning-symbol",
                                    IconElement {
                                        icon: Icon::ExclamationTriangle
                                    }
                                },
                                Label {
                                    text: get_local_text("settings-profile.remove-recovery-seed"),
                                    aria_label: "remove-phrase-label".into(),
                                },
                                p {
                                    get_local_text("settings-profile.remove-recovery-seed-description")
                                },
                                div {
                                    class: "button-group",
                                    Button {
                                        text: get_local_text("uplink.remove"),
                                        aria_label: "remove-seed-phrase-btn".into(),
                                        appearance: Appearance::Danger,
                                        icon: Icon::Trash,
                                        onpress: move |_| {
                                            // TODO: We should change the warp flag here to remove the seed phrase. Additionally we should find some way to quickly check if the phrase is stored locally so we don't show the UI for this after it's removed.
                                            remove_seed_words_ch.send(());
                                        }
                                    },
                                    Button {
                                        text: get_local_text("uplink.cancel"),
                                        aria_label: "cancel-remove-seed-phrase-btn".into(),
                                        icon: Icon::NoSymbol,
                                        appearance: Appearance::Secondary,
                                        onpress: move |_| {
                                            show_remove_seed.set(false);
                                        }
                                    }
                                }
                            }
                        }
                    )),
                )}
                if open_crop_image_modal_for_banner_picture.get().0 {
                    rsx!(CropRectImageModal {
                        large_thumbnail: open_crop_image_modal_for_banner_picture.1.clone(),
                        on_cancel: |_| {
                            open_crop_image_modal_for_banner_picture.set((false, (Vec::new(), String::new())));
                        },
                        on_crop: move |image_pathbuf: PathBuf| {
                            match transform_file_into_base64_image(image_pathbuf) {
                                Ok((img_cropped, _)) => ch.send(ChanCmd::Banner(img_cropped)),
                                Err(_) => ch.send(ChanCmd::Banner(open_crop_image_modal_for_banner_picture.1.0.clone())),
                            }
                            open_crop_image_modal_for_banner_picture.set((false, (Vec::new(), String::new())));
                        }
                    })
                }
                if open_crop_image_modal.get().0 {
                    rsx!(CropCircleImageModal {
                        large_thumbnail: open_crop_image_modal.1.clone(),
                        on_cancel: |_| {
                            open_crop_image_modal.set((false, (Vec::new(), String::new())));
                        },
                        on_crop: move |image_pathbuf: PathBuf| {
                            match transform_file_into_base64_image(image_pathbuf) {
                                Ok((img_cropped, _)) => ch.send(ChanCmd::Profile(img_cropped)),
                                Err(_) => ch.send(ChanCmd::Profile(open_crop_image_modal.1.0.clone()) ),
                            }
                            open_crop_image_modal.set((false, (Vec::new(), String::new())));
                        }
                    })
                }
            }
        }
    ))
}

fn set_profile_picture(open_crop_image_modal: UseState<(bool, (Vec<u8>, String))>) {
    match set_image() {
        Ok(img) => {
            open_crop_image_modal.set((true, img));
        }
        Err(e) => {
            log::error!("failed to set pfp: {e}");
        }
    };
}

fn set_banner(open_crop_image_modal_for_banner_picture: UseState<(bool, (Vec<u8>, String))>) {
    match set_image() {
        Ok(img) => {
            open_crop_image_modal_for_banner_picture.set((true, img));
        }
        Err(e) => {
            log::error!("failed to set banner: {e}");
        }
    };
}

fn set_image() -> Result<(Vec<u8>, String), Box<dyn std::error::Error>> {
    let path = match FileDialog::new()
        .add_filter("image", &["jpg", "png", "jpeg", "svg"])
        .set_directory(".")
        .pick_file()
    {
        Some(path) => path,
        None => return Err(Box::from(Error::InvalidItem)),
    };

    transform_file_into_base64_image(path)
}

fn transform_file_into_base64_image(
    path: std::path::PathBuf,
) -> Result<(Vec<u8>, String), Box<dyn std::error::Error>> {
    let file = std::fs::read(&path)?;

    let filename = path
        .file_name()
        .map(|file| file.to_string_lossy().to_string())
        .unwrap_or_default();

    let parts_of_filename: Vec<&str> = filename.split('.').collect();

    //Since files selected are filtered to be jpg, jpeg, png or svg the last branch is not reachable
    let mime = match parts_of_filename.last() {
        Some(m) => match *m {
            "png" => IMAGE_PNG.to_string(),
            "jpg" => IMAGE_JPEG.to_string(),
            "jpeg" => IMAGE_JPEG.to_string(),
            "svg" => IMAGE_SVG.to_string(),
            &_ => "".to_string(),
        },
        None => "".to_string(),
    };

    let prefix = match &file.len() {
        0 => "".to_string(),
        _ => format!("data:{mime};base64,"),
    };

    Ok((file, prefix))
}

fn get_input_options(validation_options: Validation) -> Options {
    // Set up options for the input field
    Options {
        // Enable validation for the input field with the specified options
        with_validation: Some(validation_options),
        clear_on_submit: false,
        clear_validation_on_submit: true,
        // Use the default options for the remaining fields
        ..Options::default()
    }
}

fn get_status_option<'a>(cx: Scope<'a>, status: &IdentityStatus) -> (String, Element<'a>) {
    let indicator = Status::from(*status);
    (
        serde_json::to_string::<IdentityStatus>(status).unwrap_or_default(),
        cx.render(rsx!(div {
                class: "settings-online-status",
                Indicator {
                    status: indicator,
                    platform: Platform::Unknown
                },
                div {
                    class: "settings-online-status-label",
                    get_local_text(&format!("settings-profile.status-{}", indicator))
                }
            }
        )),
    )
}
