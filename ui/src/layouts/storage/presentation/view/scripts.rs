pub const MAIN_SCRIPT_JS: &str = include_str!("./storage.js");

pub const FEEDBACK_TEXT_SCRIPT: &str = r#"
    const feedback_element = document.getElementById('overlay-text');
    feedback_element.textContent = '$TEXT';
"#;

pub const FILE_NAME_SCRIPT: &str = r#"
    const filename = document.getElementById('overlay-text0');
    filename.textContent = '$FILE_NAME';
"#;

pub const ANIMATION_DASH_SCRIPT: &str = r#"
    var dashElement = document.getElementById('dash-element')
    dashElement.style.animation = "border-dance 0.5s infinite linear"
"#;
