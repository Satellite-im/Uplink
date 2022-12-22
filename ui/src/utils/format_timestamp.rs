use chrono::{DateTime, Utc};
use isolang::Language;
use timeago::{languages::boxup, English};

/// Format timestamp for timeago with local language
pub fn format_timestamp_timeago(datetime: DateTime<Utc>, active_language: String) -> String {
    let language = 
        isolang::Language::from_locale(&active_language.replace('-', "_")).unwrap_or(Language::Eng);
    let formatter = match timeago::from_isolang(language) {
        Some(lang) => timeago::Formatter::with_language(lang), 
        None => timeago::Formatter::with_language(boxup(English)),
    };
    let now = Utc::now();
    let duration = now.signed_duration_since(datetime).to_std().unwrap();
    formatter.convert(duration)
}