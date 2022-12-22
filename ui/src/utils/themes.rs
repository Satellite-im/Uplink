use notify_rust::Notification;

#[cfg(target_os = "macos")]
use objc::{msg_send, sel, sel_impl};

#[allow(non_snake_case)]
pub enum Available_Themes {
    Default = "--default",
    Secondary = "--secondary",
}
