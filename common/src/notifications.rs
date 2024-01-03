use std::thread;

use crate::language::get_local_text;

use super::sounds::{Play, Sounds};
use derive_more::Display;
use notify_rust::Notification;
use std::sync::Arc;
use uuid::Uuid;
use warp::logging::tracing::log;

use once_cell::sync::Lazy;
use tokio::sync::{
    broadcast,
    mpsc::{UnboundedReceiver, UnboundedSender},
    Mutex,
};

#[cfg(target_os = "windows")]
pub const POWERSHELL_APP_ID: &str = "{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\
\\WindowsPowerShell\\v1.0\\powershell.exe";

#[derive(Debug, Clone, Display)]
pub enum NotificationAction {
    #[display(fmt = "DisplayChat")]
    DisplayChat(Uuid),
    #[display(fmt = "FriendListPending")]
    FriendListPending,
    #[display(fmt = "Dummy")]
    Dummy,
}

pub struct NotificationChannel {
    pub tx: broadcast::Sender<NotificationAction>,
}

pub static NOTIFICATION_LISTENER: Lazy<NotificationChannel> = Lazy::new(|| {
    let (tx, _) = tokio::sync::broadcast::channel(128);
    NotificationChannel { tx }
});

pub struct FocusChannel {
    pub tx: UnboundedSender<()>,
    pub rx: Arc<Mutex<UnboundedReceiver<()>>>,
}

// We also dont always have a reference to the current window when pushing a notification
// As such we use a channel to notify the app to refocus the window instead
pub static FOCUS_SCHEDULER: Lazy<FocusChannel> = Lazy::new(|| {
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
    FocusChannel {
        tx,
        rx: Arc::new(Mutex::new(rx)),
    }
});

#[allow(non_snake_case)]
pub fn push_notification(
    title: String,
    content: String,
    notification_sound: Option<Sounds>,
    timeout: notify_rust::Timeout,
    action: NotificationAction,
) {
    let summary = format!("Uplink - {title}");
    thread::spawn(move || {
        let action_id = format!("toast_actions.{}", action);
        show_with_action(
            Notification::new()
                .summary(summary.as_ref())
                .body(&content)
                .timeout(timeout)
                .action(&action_id, &get_local_text(&action_id))
                .finalize(),
            action_id,
            action,
        );
    });

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

// We need to handle them all differently as there isnt a single lib that covers it for all
fn show_with_action(notification: Notification, action_id: String, action: NotificationAction) {
    #[cfg(target_os = "windows")]
    {
        // Notify-rust does not support windows actions so we use the underlying system directly
        // See https://gist.github.com/allenbenz/a0fb225aef43df4b1be1c005fb4c2811 for general idea
        let duration = match notification.timeout {
            notify_rust::Timeout::Default => "duration=\"short\"",
            notify_rust::Timeout::Never => "duration=\"long\"",
            notify_rust::Timeout::Milliseconds(t) => {
                if t >= 25000 {
                    "duration=\"long\""
                } else {
                    "duration=\"short\""
                }
            }
        };
        //TODO set proper app id
        let app_id = POWERSHELL_APP_ID.to_string();
        let template_binding = "ToastGeneric";
        let actions = format!(
            r#"<action content="{}" arguments="{}"/>"#,
            &get_local_text(&action_id),
            &action_id
        );

        let toast_xml = windows::Data::Xml::Dom::XmlDocument::new().unwrap();
        if let Err(err) = toast_xml.LoadXml(&windows::runtime::HSTRING::from(format!(
            "<toast {} {}>
                    <visual>
                        <binding template=\"{}\">
                        {}
                        {}{}{}
                        </binding>
                    </visual>
                    {}
                    <actions>
                        {}
                    </actions>
                </toast>",
            duration,
            String::new(), //Scenario
            template_binding,
            &notification.icon,
            &notification.summary,
            notification.subtitle.as_ref().map_or("", AsRef::as_ref),
            &notification.body,
            r#"<audio silent='true'/>"#, //Already handled in uplink
            actions
        ))) {
            log::error!("Error creating windows toast xml {}", err);
            return;
        };

        // Create the toast
        let toast_notification =
            match windows::UI::Notifications::ToastNotification::CreateToastNotification(&toast_xml)
            {
                Ok(toast_notification) => toast_notification,
                Err(err) => {
                    log::error!("Error creating windows toast {}", err);
                    return;
                }
            };
        if let Err(err) = toast_notification.Activated(windows::Foundation::TypedEventHandler::new(
            move |_sender, result: &Option<windows::runtime::IInspectable>| {
                let event: Option<
                    windows::runtime::Result<windows::UI::Notifications::ToastActivatedEventArgs>,
                > = result.as_ref().map(windows::runtime::Interface::cast);
                let arguments = event
                    .and_then(|val| val.ok())
                    .and_then(|args| args.Arguments().ok());
                if let Some(val) = arguments {
                    if val.to_string_lossy().eq(&action_id) {
                        log::trace!("toast action activated {:?}", val);
                        let tx = NOTIFICATION_LISTENER.tx.clone();
                        if let Err(e) = tx.send(action.to_owned()) {
                            log::error!("failed to send notification action {}", e);
                        }
                        let focus = FOCUS_SCHEDULER.tx.clone();
                        if let Err(e) = focus.send(()) {
                            log::error!("failed to send focus command {}", e);
                        }
                    }
                };
                Ok(())
            },
        )) {
            log::error!("Error creating windows toast action {}", err);
            return;
        };

        match windows::UI::Notifications::ToastNotificationManager::CreateToastNotifierWithId(
            &windows::runtime::HSTRING::from(&app_id),
        ) {
            Ok(toast_notifier) => {
                if let Err(err) = toast_notifier.Show(&toast_notification) {
                    log::error!("Error showing windows toast {}", err);
                }
            }
            Err(err) => log::error!("Error handling notification {}", err),
        }
    }

    #[cfg(target_os = "macos")]
    {
        // Notify-rust does not support macos actions but the underlying mac_notification library does
        let action_name = &get_local_text(&action_id);
        match mac_notification_sys::Notification::default()
            .title(notification.summary.as_str())
            .message(&notification.body)
            .maybe_subtitle(notification.subtitle.as_deref())
            .main_button(mac_notification_sys::MainButton::SingleAction(action_name))
            .send()
        {
            Ok(response) => match response {
                mac_notification_sys::NotificationResponse::ActionButton(id) => {
                    if action_name.eq(&id) {
                        let tx = NOTIFICATION_LISTENER.tx.clone();
                        if let Err(e) = tx.send(action) {
                            log::error!("failed to send notification action {}", e);
                        }
                        let focus = FOCUS_SCHEDULER.tx.clone();
                        if let Err(e) = focus.send(()) {
                            log::error!("failed to send focus command {}", e);
                        }
                    };
                }
                mac_notification_sys::NotificationResponse::Click => {
                    let focus = FOCUS_SCHEDULER.tx.clone();
                    if let Err(e) = focus.send(()) {
                        log::error!("failed to send focus command {}", e);
                    }
                }
                _ => {}
            },
            Err(err) => log::error!("Error handling notification {}", err),
        }
    }

    #[cfg(target_os = "linux")]
    {
        match notification.show() {
            Ok(handle) => handle.wait_for_action(|id| {
                if action_id.eq(id) {
                    let tx = NOTIFICATION_LISTENER.tx.clone();
                    if let Err(e) = tx.send(action) {
                        log::error!("failed to send notification action {}", e);
                    }
                    let focus = FOCUS_SCHEDULER.tx.clone();
                    if let Err(e) = focus.send(()) {
                        log::error!("failed to send focus command {}", e);
                    }
                };
            }),
            Err(err) => log::error!("Error handling notification {}", err),
        }
    }
}
