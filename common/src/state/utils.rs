use std::{
    fs,
    path::{Path, PathBuf},
};

use titlecase::titlecase;
use tracing::log;
use walkdir::WalkDir;

use crate::{get_extras_dir, STATIC_ARGS};

use super::{ui::Font, Theme};

pub fn get_available_themes() -> Vec<Theme> {
    let mut themes = vec![];

    let mut add_to_themes = |themes_path: &PathBuf| {
        log::debug!("add_to_themes: {}", themes_path.to_string_lossy());
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

    let default = Theme {
        filename: "".into(),
        name: "Default".into(),
        styles: "".into(),
    };

    themes.push(default);

    themes.dedup(); // Why are we deduping here? We check above to only add if the theme doesn't already exist

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
