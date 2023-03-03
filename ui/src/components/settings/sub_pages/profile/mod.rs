use common::language::get_local_text;
use common::state::State;
use common::warp_runner::{MultiPassCmd, WarpCmd};
use common::{icons::outline::Shape as Icon, WARP_CMD_CH};
use dioxus::prelude::*;
use futures::channel::oneshot;
use futures::StreamExt;
use kit::elements::{
    button::Button,
    input::{Input, Options, Validation},
    label::Label,
};
use mime::*;
use rfd::FileDialog;
use warp::multipass;
use warp::{error::Error, logging::tracing::log};

#[derive(Clone)]
enum ChanCmd {
    Profile(String),
    Banner(String),
    Username(String),
    Status(String),
}

#[allow(non_snake_case)]
pub fn ProfileSettings(cx: Scope) -> Element {
    log::trace!("rendering ProfileSettings");

    let state = use_shared_state::<State>(cx)?;
    let user_status = state
        .read()
        .account
        .identity
        .status_message()
        .unwrap_or_default();
    let username = state.read().account.identity.username();
    let should_update: &UseState<Option<multipass::identity::Identity>> = use_state(cx, || None);
    // TODO: This needs to persist across restarts but a config option seems overkill. Should we have another kind of file to cache flags?
    let welcome_dismissed = use_state(&cx, || false);
    let image = state.read().account.identity.graphics().profile_picture();
    let banner = state.read().account.identity.graphics().profile_banner();

    if let Some(ident) = should_update.get() {
        log::trace!("Updating ProfileSettings");
        state
            .write()
            .account
            .identity
            .set_warp_identity(ident.clone());
        should_update.set(None);
    }

    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<ChanCmd>| {
        to_owned![should_update];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some(cmd) = rx.next().await {
                // this is lazy but I can get away with it for now
                let (tx, rx) = oneshot::channel();
                let warp_cmd = match cmd {
                    ChanCmd::Profile(pfp) => MultiPassCmd::UpdateProfilePicture { pfp, rsp: tx },
                    ChanCmd::Banner(banner) => MultiPassCmd::UpdateBanner { banner, rsp: tx },
                    ChanCmd::Username(username) => {
                        MultiPassCmd::UpdateUsername { username, rsp: tx }
                    }
                    ChanCmd::Status(status) if status.is_empty() => MultiPassCmd::UpdateStatus {
                        status: None,
                        rsp: tx,
                    },
                    ChanCmd::Status(status) => MultiPassCmd::UpdateStatus {
                        status: Some(status),
                        rsp: tx,
                    },
                };

                if let Err(e) = warp_cmd_tx.send(WarpCmd::MultiPass(warp_cmd)) {
                    log::error!("failed to send warp command: {}", e);
                    continue;
                }

                let res = rx.await.expect("command cancelled");
                match res {
                    Ok(ident) => {
                        should_update.set(Some(ident));
                    }
                    Err(e) => log::error!("failed to update identity: {e}"),
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

    let change_banner_text = get_local_text("settings-profile.change-banner");
    cx.render(rsx!(
        div {
            id: "settings-profile",
            aria_label: "settings-profile",
            (!welcome_dismissed).then(|| rsx!(
                div {
                    class: "new-profile-welcome",
                    div {
                        class: "welcome",
                        img {
                            src: "./ui/extra/images/mascot/working.png"
                        },
                    },
                    div {
                        class: "welcome-content",
                        Button {
                            text: get_local_text("uplink.dismiss"),
                            icon: Icon::XMark,
                            onpress: move |_| {
                                welcome_dismissed.set(true);
                            }
                        },
                        Label {
                            text: get_local_text("settings-profile.welcome")
                        },
                        p {
                            get_local_text("settings-profile.welcome-desc")
                        }
                        br {},
                        p {
                            get_local_text("settings-profile.welcome-cta")
                        }
                    }
                },
            ))
            div {
                class: "profile-header",
                aria_label: "profile-header",
                div {
                    class: "profile-banner",
                    aria_label: "profile-banner",
                    style: "background-image: url({banner});",
                    onclick: move |_| {
                        set_banner( ch.clone());
                    },
                    p {class: "change-banner-text", "{change_banner_text}" },
                },
                div {
                    class: "profile-picture",
                    aria_label: "profile-picture",
                    style: "background-image: url({image});",
                    onclick: move |_| {
                        set_profile_picture(ch.clone());
                    },
                    Button {
                        icon: Icon::Plus,
                        aria_label: "add-picture-button".into(),
                        onpress: move |_| {
                           set_profile_picture(ch.clone());
                        }
                    },
                }
            },
            div{
                class: "profile-content",
                aria_label: "profile-content",
                div {
                    class: "plus-button",
                    Button {
                        icon: Icon::Plus,
                        onpress: move |_| {
                            set_profile_picture( ch.clone());
                        }
                    }
                },
                div {
                    class: "content-item",
                    Label {
                        text: get_local_text("uplink.username"),
                    },
                    Input {
                        placeholder:  get_local_text("uplink.username"),
                        default_text: username,
                        aria_label: "username-input".into(),
                        options: get_input_options(username_validation_options),
                        onreturn: move |(v, is_valid, _): (String, bool, _)| {
                            if !is_valid {
                                return;
                            }
                            ch.send(ChanCmd::Username(v));
                        },
                    },
                },
                div {
                    class: "content-item",
                    Label {
                        text: get_local_text("uplink.status"),
                    },
                    Input {
                        placeholder: get_local_text("uplink.status"),
                        default_text: user_status,
                        aria_label: "status-input".into(),
                        options: Options {
                            with_clear_btn: true,
                            ..get_input_options(status_validation_options)
                        }
                        onreturn: move |(v, is_valid, _): (String, bool, _)| {
                            if !is_valid {
                                return;
                            }
                            ch.send(ChanCmd::Status(v));
                        },
                    }
                }
            }
        }
    ))
}

fn set_profile_picture(ch: Coroutine<ChanCmd>) {
    match set_image() {
        Ok(img) => {
            ch.send(ChanCmd::Profile(img));
        }
        Err(e) => {
            log::error!("failed to set pfp: {e}");
        }
    };
}

fn set_banner(ch: Coroutine<ChanCmd>) {
    match set_image() {
        Ok(img) => {
            ch.send(ChanCmd::Banner(img));
        }
        Err(e) => {
            log::error!("failed to set banner: {e}");
        }
    };
}

fn set_image() -> Result<String, Box<dyn std::error::Error>> {
    let path = match FileDialog::new()
        .add_filter("image", &["jpg", "png", "jpeg", "svg"])
        .set_directory(".")
        .pick_file()
    {
        Some(path) => path,
        None => return Err(Box::from(Error::InvalidItem)),
    };

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

    let image = match &file.len() {
        0 => "".to_string(),
        _ => {
            let prefix = format!("data:{mime};base64,");
            let base64_image = base64::encode(&file);
            let img = prefix + base64_image.as_str();
            img
        }
    };

    Ok(image)
}

fn get_input_options(validation_options: Validation) -> Options {
    // Set up options for the input field
    Options {
        // Enable validation for the input field with the specified options
        with_validation: Some(validation_options),
        clear_on_submit: false,
        // Use the default options for the remaining fields
        ..Options::default()
    }
}
