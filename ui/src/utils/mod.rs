use common::{
    get_extras_dir,
    state::{self, ui::Font, Theme},
    STATIC_ARGS,
};
use filetime::FileTime;
use warp::logging::tracing::log;

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
    if let Ok(p) = get_extras_dir() {
        add_to_themes(&p.join("themes"));
    }

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

pub fn unzip_prism_langs() {
    if !STATIC_ARGS.production_mode || !cfg!(target_os = "windows") {
        return;
    }
    log::debug!("unzip_prism_langs");
    let exe_path = match std::env::current_exe() {
        Ok(p) => p,
        Err(e) => {
            log::error!("failed to get path of uplink executable: {e}");
            return;
        }
    };

    let current_version = env!("CARGO_PKG_VERSION");
    let assets_version_file = STATIC_ARGS.dot_uplink.join("assets_version.txt");
    let assets_version = std::fs::read_to_string(&assets_version_file).unwrap_or_default();
    if current_version == assets_version {
        let exe_meta =
            fs::metadata(&exe_path).expect("failed to get metadata for uplink executable");
        let version_meta =
            fs::metadata(&assets_version_file).expect("failed to get metadata for assets version");
        let exe_changed = FileTime::from_last_modification_time(&exe_meta);
        let assets_changed = FileTime::from_last_modification_time(&version_meta);
        if assets_changed > exe_changed {
            log::debug!("assets already exist");
            return;
        } else {
            log::debug!("re-install suspected. copying over assets");
        }
    }

    let prism_src = exe_path
        .parent()
        .and_then(|x| x.parent())
        .map(|x| x.join("extra").join("prism_langs.zip"))
        .ok_or(anyhow::format_err!("failed to get prism_langs.zip"));

    let prism_src = match prism_src {
        Ok(p) => p,
        Err(e) => {
            log::error!("{e}");
            return;
        }
    };

    let prism_dest = STATIC_ARGS.dot_uplink.join("prism_langs");

    if let Err(e) = std::fs::remove_dir_all(&prism_dest) {
        log::error!("failed to delete old prism_lang directory: {e}");
    }
    if let Err(e) = unzip_archive(&prism_src, &prism_dest) {
        log::error!("failed to unizp prism_lang archive {prism_src:?}: {e}");
    }

    if let Err(e) = std::fs::write(assets_version_file, current_version) {
        log::error!("failed to save assets_version_file: {e}");
    }
}

// taken from https://github.com/zip-rs/zip/blob/master/examples/extract.rs
fn unzip_archive(src: &Path, dest: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let assets_zip = fs::File::open(src)?;
    let mut archive = zip::ZipArchive::new(assets_zip)?;
    for idx in 0..archive.len() {
        let mut file = archive.by_index(idx)?;
        let outpath = match file.enclosed_name() {
            Some(path) => dest.join(path),
            None => continue,
        };
        if (*file.name()).ends_with('/') || (*file.name()).ends_with('\\') {
            fs::create_dir_all(&outpath)?;
        } else {
            if let Some(p) = outpath.parent() {
                if !p.exists() {
                    fs::create_dir_all(p)?;
                }
            }
            let mut outfile = fs::File::create(&outpath)?;
            std::io::copy(&mut file, &mut outfile)?;
        }
    }

    Ok(())
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
