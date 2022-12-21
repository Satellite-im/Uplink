use crate::sounds::{Play, Sounds};
use notify_rust::Notification;

#[cfg(target_os = "macos")]
use objc::{msg_send, sel, sel_impl};

// Implementation to create and push new notifications
#[allow(non_snake_case)]
pub fn PushNotification(title: String, content: String, notification_sound: Sounds) {
    let summary = format!("Uplink - {}", title);
    let _n = Notification::new()
        .summary(summary.as_ref())
        .body(&content)
        .show();
    // Play notification sound
    Play(notification_sound);
}

pub fn set_badge(count: u32) -> Result<(), String> {
    #[cfg(not(target_os = "macos"))]
    let _ = count;
    #[cfg(target_os = "macos")]
    unsafe {
        use cocoa::{appkit::NSApp, base::nil, foundation::NSString};

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
