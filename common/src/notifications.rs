use super::sounds::{Play, Sounds};
use notify_rust::Notification;

// Implementation to create and push new notifications
#[allow(non_snake_case)]
pub fn push_notification(
    title: String,
    content: String,
    notification_sound: Option<Sounds>,
    timeout: notify_rust::Timeout,
) {
    let summary = format!("Uplink - {title}");
    let _n = Notification::new()
        .summary(summary.as_ref())
        .body(&content)
        .timeout(timeout)
        .show();

    if let Some(sound) = notification_sound {
        Play(sound);
    }
}

pub fn set_badge(count: u32) -> Result<(), String> {
    #[cfg(not(target_os = "macos"))]
    let _ = count;
    #[cfg(target_os = "macos")]
    unsafe {
        use cocoa::{appkit::NSApp, base::nil, foundation::NSString};
        use objc::{msg_send, sel, sel_impl};

        let label = if count == 0 {
            nil
        } else {
            NSString::alloc(nil).init_str(&format!("{}", count))
        };
        let dock_tile: cocoa::base::id = msg_send![NSApp(), dockTile];
        let _: cocoa::base::id = msg_send![dock_tile, setBadgeLabel: label];
    }
    Ok(())
}
