// although it's annoying to not immediately see the contents of the script when you ctrl+click the variable,
// it is easier to read and write the script when it's in a separate .js file. Having a folder of .js scripts
// also makes it easier to see what scripts are available.

pub const SETUP_CONTEXT_PARENT: &str = include_str!("./setup_context_parent.js");
pub const SHOW_CONTEXT: &str = include_str!("./show_context.js");
pub const SCROLL_TO_TOP: &str = include_str!("./scroll_to_top.js");
pub const SCROLL_TO_BOTTOM: &str = include_str!("./scroll_to_bottom.js");
pub const OBSERVER_SCRIPT: &str = include_str!("./observer_script.js");
