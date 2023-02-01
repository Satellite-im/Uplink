//! Defines important types and structs, and spawns the main task for warp_runner - manager::run.
use std::sync::Arc;

use tokio::sync::{
    mpsc::{UnboundedReceiver, UnboundedSender},
    Mutex, Notify,
};
use warp::{
    constellation::Constellation, logging::tracing::log, multipass::MultiPass, raygun::RayGun,
    tesseract::Tesseract,
};
use warp_fs_ipfs::config::FsIpfsConfig;
use warp_mp_ipfs::config::MpIpfsConfig;
use warp_rg_ipfs::config::RgIpfsConfig;

use crate::{STATIC_ARGS, WARP_CMD_CH};

use self::ui_adapter::{MultiPassEvent, RayGunEvent};

mod conv_stream;
mod manager;
pub mod ui_adapter;

pub use manager::{MultiPassCmd, RayGunCmd, TesseractCmd};

pub type WarpCmdTx = UnboundedSender<WarpCmd>;
pub type WarpCmdRx = Arc<Mutex<UnboundedReceiver<WarpCmd>>>;
pub type WarpEventTx = UnboundedSender<WarpEvent>;
pub type WarpEventRx = Arc<Mutex<UnboundedReceiver<WarpEvent>>>;

pub struct WarpCmdChannels {
    pub tx: WarpCmdTx,
    pub rx: WarpCmdRx,
}

pub struct WarpEventChannels {
    pub tx: WarpEventTx,
    pub rx: WarpEventRx,
}

type Account = Box<dyn MultiPass>;
type Storage = Box<dyn Constellation>;
type Messaging = Box<dyn RayGun>;

#[allow(clippy::large_enum_variant)]
pub enum WarpEvent {
    RayGun(RayGunEvent),
    Message(ui_adapter::MessageEvent),
    MultiPass(MultiPassEvent),
}

pub enum WarpCmd {
    Tesseract(TesseractCmd),
    MultiPass(MultiPassCmd),
    RayGun(RayGunCmd),
}

impl std::fmt::Display for WarpCmd {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            WarpCmd::MultiPass(cmd) => write!(f, "WarpCmd::MultiPass {{ {cmd} }} "),
            WarpCmd::Tesseract(cmd) => write!(f, "WarpCmd::Tesseract {{ {cmd:?} }} "),
            WarpCmd::RayGun(cmd) => write!(f, "WarpCmd::RayGun {{ {cmd:?} }} "),
        }
    }
}

/// Spawns a task which manages multiple streams, channels, and tasks related to warp
pub struct WarpRunner {
    // perhaps collecting a JoinHandle and calling abort() would be better than using Notify.
    notify: Arc<Notify>,
    ran_once: bool,
}

impl std::ops::Drop for WarpRunner {
    fn drop(&mut self) {
        self.notify.notify_waiters();
    }
}

impl WarpRunner {
    pub fn new() -> Self {
        Self {
            notify: Arc::new(Notify::new()),
            ran_once: false,
        }
    }

    // spawns a task which will terminate when WarpRunner is dropped
    pub fn run(&mut self) {
        assert!(!self.ran_once, "WarpRunner called run() multiple times");
        self.ran_once = true;

        let notify = self.notify.clone();
        tokio::spawn(async move {
            handle_login(notify.clone()).await;
        });
    }
}

// handle_login calls manager::run, which continues to process warp commands
async fn handle_login(notify: Arc<Notify>) {
    let warp_cmd_rx = WARP_CMD_CH.rx.clone();
    // be sure to drop this channel before calling manager::run()
    let mut warp_cmd_rx = warp_cmd_rx.lock().await;
    let tesseract = init_tesseract();

    // until the user logs in, raygun and multipass are no use.
    let warp: Option<manager::Warp> = loop {
        tokio::select! {
            opt = warp_cmd_rx.recv() => {
                if let Some(cmd) = &opt {
                    log::debug!("received {}", cmd);
                }

                match opt {
                Some(WarpCmd::MultiPass(MultiPassCmd::CreateIdentity {
                    username,
                    passphrase,
                    rsp,
                })) => {
                    tesseract.clear();
                    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                    let new_account = true;
                    let mut warp = match login(&passphrase, tesseract.clone(), new_account).await {
                        Ok(w) => w,
                        Err(e) => {
                            let _ = rsp.send(Err(e));
                            continue;
                        }
                    };
                    match warp.multipass.create_identity(Some(&username), None).await {
                        Ok(_id) => {
                            // don't want a panic during the first run of the app to mess up tesseract.
                            // calling save() here is intended to ensure that the username and password will
                            // work the next time uplink is run.
                            let _ = warp.tesseract.save();

                            let _ = rsp.send(Ok(()));
                            break Some(warp);
                        }
                        Err(e) => {
                            log::error!("create_identity failed. should never happen: {}", e);
                            let _ = rsp.send(Err(e));
                        }
                    }
                }
                Some(WarpCmd::MultiPass(MultiPassCmd::TryLogIn { passphrase, rsp })) => {
                    let new_account = false;
                    let warp = match login(&passphrase, tesseract.clone(), new_account).await {
                        Ok(w) => w,
                        Err(e) => {
                            let _ = rsp.send(Err(e));
                            continue;
                        }
                    };
                    log::debug!("TryLogIn unlocked tesseract");
                    let r = warp.multipass.get_own_identity().await.map(|_| ());
                    let is_ok = r.is_ok();
                    let _ = rsp.send(r);
                    if is_ok {
                        break Some(warp);
                    }
                }
                Some(WarpCmd::Tesseract(TesseractCmd::KeyExists { key, rsp }))  => {
                    let res = tesseract.exist(&key);
                    let _ = rsp.send(res);
                }
                _ => {}
                }
            } ,
            // the WarpRunner has been dropped. stop the task
            _ = notify.notified() => break None,
        }
    };

    // release the lock
    drop(warp_cmd_rx);
    if let Some(warp) = warp {
        manager::run(warp, notify).await;
    } else {
        log::info!("warp_runner terminated during initialization");
    }
}

fn init_tesseract() -> Tesseract {
    log::trace!("initializing tesseract");
    let tess_path = STATIC_ARGS.warp_path.join(".keystore");
    match Tesseract::from_file(&tess_path) {
        Ok(tess) => tess,
        Err(_) => {
            //doesnt exist so its set
            log::trace!("creating new tesseract");
            let tess = Tesseract::default();
            tess.set_file(tess_path);
            tess.set_autosave();
            tess
        }
    }
}

// tesseract needs to be initialized before warp is initialized. this function does just that
async fn login(
    passphrase: &str,
    tesseract: Tesseract,
    new_account: bool,
) -> Result<manager::Warp, warp::error::Error> {
    log::debug!("login");
    tesseract.unlock(passphrase.as_bytes())?;
    while !tesseract.is_unlock() {
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }

    if !new_account && !tesseract.exist("keypair") {
        log::info!("string keypair not found in tesseract");
        return Err(warp::error::Error::IdentityNotCreated);
    }
    let res = warp_initialization(tesseract, false).await;
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    res
}

// tesseract needs to be initialized before warp is initialized. need to call this function again once tesseract is unlocked by the password
async fn warp_initialization(
    tesseract: Tesseract,
    experimental: bool,
) -> Result<manager::Warp, warp::error::Error> {
    log::debug!("warp initialization");
    let path = &STATIC_ARGS.warp_path;
    let config = MpIpfsConfig::production(path, experimental);

    let account = warp_mp_ipfs::ipfs_identity_persistent(config, tesseract.clone(), None)
        .await
        .map(|mp| Box::new(mp) as Account)?;

    let storage = warp_fs_ipfs::IpfsFileSystem::<warp_fs_ipfs::Persistent>::new(
        account.clone(),
        Some(FsIpfsConfig::production(path)),
    )
    .await
    .map(|ct| Box::new(ct) as Storage)?;

    // FYI: setting `rg_config.store_setting.disable_sender_event_emit` to `true` will prevent broadcasting `ConversationCreated` on the sender side
    let rg_config = RgIpfsConfig::production(path);

    let messaging = warp_rg_ipfs::IpfsMessaging::<warp_mp_ipfs::Persistent>::new(
        Some(rg_config),
        account.clone(),
        Some(storage.clone()),
        None,
    )
    .await
    .map(|rg| Box::new(rg) as Messaging)?;

    Ok(manager::Warp {
        tesseract,
        multipass: account,
        raygun: messaging,
        _constellation: storage,
    })
}
