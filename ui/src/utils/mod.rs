use common::{
    state::{self, Theme},
    STATIC_ARGS,
};
use kit::components::indicator::{Status};
use std::{fs, path::Path};
use titlecase::titlecase;
use walkdir::WalkDir;

use kit::User as UserInfo;

pub mod format_timestamp;

pub fn get_available_themes() -> Vec<Theme> {
    let mut themes = vec![];

    for file in WalkDir::new(&STATIC_ARGS.themes_path)
        .into_iter()
        .filter_map(|file| file.ok())
    {
        if file.metadata().unwrap().is_file() {
            let theme_path = file.path().display().to_string();
            let pretty_theme_str = get_pretty_name(&theme_path);
            let pretty_theme_str = titlecase(&pretty_theme_str);

            let styles = fs::read_to_string(&theme_path).unwrap_or_default();

            let theme = Theme {
                filename: theme_path.to_owned(),
                name: pretty_theme_str.to_owned(),
                styles,
            };

            themes.push(theme);
        }
    }
    themes.sort_by_key(|theme| theme.name.clone());

    themes
}

fn get_pretty_name<S: AsRef<str>>(name: S) -> String {
    let path = Path::new(name.as_ref());
    let last = path
        .file_name()
        .and_then(|p| Path::new(p).file_stem())
        .unwrap_or_default();
    last.to_string_lossy().into()
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
        let platform = identity.platform().into();
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
    let platform = identity.platform().into();
    UserInfo {
        platform,
        status: convert_status(&identity.identity_status()),
        username: identity.username(),
        photo: identity.graphics().profile_picture(),
    }
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn test_get_pretty_name1() {
        if cfg!(windows) {
            let r = get_pretty_name("c:\\pretty\\name2.scss");
            assert_eq!(r, String::from("name2"));
        } else {
            let r = get_pretty_name("pretty/name1.scss");
            assert_eq!(r, String::from("name1"));
        }
    }
}
