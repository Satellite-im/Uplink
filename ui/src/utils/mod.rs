use kit::components::indicator::{self, Status};
use std::fs;
use titlecase::titlecase;
use walkdir::WalkDir;

use crate::state::{self, Theme};
use kit::User as UserInfo;

pub mod format_timestamp;
pub mod notifications;
pub mod sounds;

pub fn get_available_themes() -> Vec<Theme> {
    let mut themes = vec![];

    let theme_path = dirs::home_dir()
        .unwrap_or_default()
        .join(".uplink/")
        .join("themes");

    for file in WalkDir::new(theme_path)
        .into_iter()
        .filter_map(|file| file.ok())
    {
        if file.metadata().unwrap().is_file() {
            let theme = file.path().display().to_string();

            let theme_str = theme.split('/').last().unwrap();
            let pretty_theme_str = &theme_str.replace(".scss", "");
            let pretty_theme_str = titlecase(pretty_theme_str);

            let styles = fs::read_to_string(&theme).unwrap_or_default();

            let theme = Theme {
                filename: theme_str.to_owned(),
                name: pretty_theme_str.to_owned(),
                styles,
            };

            themes.push(theme);
        }
    }

    themes
}

// converts from Warp IdentityStatus to ui_kit Status
pub fn convert_status(status: &warp::multipass::identity::IdentityStatus) -> Status {
    match status {
        warp::multipass::identity::IdentityStatus::Online => Status::Online,
        warp::multipass::identity::IdentityStatus::Away => Status::Idle,
        warp::multipass::identity::IdentityStatus::Busy => Status::DoNotDisturb,
        warp::multipass::identity::IdentityStatus::Offline => Status::Offline,
    }
}

pub fn build_participants(identities: &Vec<state::Identity>) -> Vec<UserInfo> {
    // Create a vector of UserInfo objects to store the results
    let mut user_info: Vec<UserInfo> = vec![];

    // Iterate over the identities vector
    for identity in identities {
        // For each identity, create a new UserInfo object and set its fields
        // to the corresponding values from the identity object
        let platform = match identity.platform() {
            warp::multipass::identity::Platform::Desktop => indicator::Platform::Desktop,
            warp::multipass::identity::Platform::Mobile => indicator::Platform::Mobile,
            _ => indicator::Platform::Headless, //TODO: Unknown
        };
        user_info.push(UserInfo {
            platform,
            status: convert_status(&identity.identity_status()),
            username: identity.username(),
            photo: identity.graphics().profile_picture(),
        })
    }

    // Return the resulting user_info vector
    user_info
}

pub fn build_user_from_identity(identity: state::Identity) -> UserInfo {
    let platform = match identity.platform() {
        warp::multipass::identity::Platform::Desktop => indicator::Platform::Desktop,
        warp::multipass::identity::Platform::Mobile => indicator::Platform::Mobile,
        _ => indicator::Platform::Headless, //TODO: Unknown
    };
    UserInfo {
        platform,
        status: convert_status(&identity.identity_status()),
        username: identity.username(),
        photo: identity.graphics().profile_picture(),
    }
}
