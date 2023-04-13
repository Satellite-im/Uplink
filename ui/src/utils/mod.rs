use common::{
    state::{self, ui::Font, Theme},
    STATIC_ARGS,
};

use std::{fs, path::Path};
use titlecase::titlecase;

use walkdir::WalkDir;

use kit::User as UserInfo;

use crate::{window_manager::WindowManagerCmd, WINDOW_CMD_CH};

pub mod auto_updater;
pub mod format_timestamp;
pub mod lifecycle;

pub fn get_available_themes() -> Vec<Theme> {
    let mut themes = vec![];

    let mut add_to_themes = |themes_path| {
        for file in WalkDir::new(themes_path)
            .into_iter()
            .filter_map(|file| file.ok())
        {
            if file.metadata().map(|x| x.is_file()).unwrap_or(false) {
                let theme_path = file.path().display().to_string();
                let pretty_theme_str = get_pretty_name(&theme_path);
                let pretty_theme_str = titlecase(&pretty_theme_str);

                let styles = fs::read_to_string(&theme_path).unwrap_or_default();

                let theme = Theme {
                    filename: theme_path.to_owned(),
                    name: pretty_theme_str.to_owned(),
                    styles,
                };
                if !themes.contains(&theme) {
                    themes.push(theme);
                }
            }
        }
    };
    add_to_themes(&STATIC_ARGS.themes_path);
    add_to_themes(&STATIC_ARGS.extras_path.join("themes"));

    themes.sort_by_key(|theme| theme.name.clone());
    themes.dedup();

    themes
}

pub fn get_available_fonts() -> Vec<Font> {
    let mut fonts = vec![];

    for file in WalkDir::new(&STATIC_ARGS.fonts_path)
        .into_iter()
        .filter_map(|file| file.ok())
    {
        if file.metadata().map(|x| x.is_file()).unwrap_or(false) {
            let file_osstr = file.file_name();
            let mut pretty_name: String = file_osstr.to_str().unwrap_or_default().into();
            pretty_name = pretty_name
                .replace(['_', '-'], " ")
                .split('.')
                .next()
                .unwrap()
                .into();

            let font = Font {
                name: pretty_name,
                path: file.path().to_str().unwrap_or_default().into(),
            };

            fonts.push(font);
        }
    }

    fonts
}

fn get_pretty_name<S: AsRef<str>>(name: S) -> String {
    let path = Path::new(name.as_ref());
    let last = path
        .file_name()
        .and_then(|p| Path::new(p).file_stem())
        .unwrap_or_default();
    last.to_string_lossy().into()
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
            status: identity.identity_status().into(),
            username: identity.username(),
            photo: identity.profile_picture(),
        })
    }

    // Return the resulting user_info vector
    user_info
}

pub fn build_user_from_identity(identity: state::Identity) -> UserInfo {
    let platform = identity.platform().into();
    UserInfo {
        platform,
        status: identity.identity_status().into(),
        username: identity.username(),
        photo: identity.profile_picture(),
    }
}

pub struct WindowDropHandler {
    cmd: WindowManagerCmd,
}

impl PartialEq for WindowDropHandler {
    fn eq(&self, _other: &Self) -> bool {
        false
    }
}

impl WindowDropHandler {
    pub fn new(cmd: WindowManagerCmd) -> Self {
        Self { cmd }
    }
}

impl Drop for WindowDropHandler {
    fn drop(&mut self) {
        let cmd_tx = WINDOW_CMD_CH.tx.clone();
        if let Err(_e) = cmd_tx.send(self.cmd) {
            // todo: log error
        }
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
