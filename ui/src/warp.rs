use std::{
    ops::{Deref, DerefMut},
    path::PathBuf,
    sync::Arc,
};

use tokio::sync::{
    mpsc::{UnboundedReceiver, UnboundedSender},
    Mutex, Notify,
};
use warp::{
    constellation::Constellation, multipass::MultiPass, raygun::RayGun, tesseract::Tesseract,
};
use warp_fs_ipfs::config::FsIpfsConfig;
use warp_mp_ipfs::config::MpIpfsConfig;
use warp_rg_ipfs::{config::RgIpfsConfig, Persistent};

use crate::DEFAULT_PATH;

pub type WarpCmdTx = UnboundedSender<WarpCmd>;
pub type WarpCmdRx = Arc<Mutex<UnboundedReceiver<WarpCmd>>>;
pub type WarpEventTx = UnboundedSender<WarpEvent>;
pub type WarpEventRx = Arc<Mutex<UnboundedReceiver<WarpEvent>>>;

pub enum WarpEvent {
    None,
}

pub enum WarpCmd {
    None,
}

pub struct WarpRunner {
    notify: Arc<Notify>,
    ran_once: bool,
}

impl std::ops::Drop for WarpRunner {
    fn drop(&mut self) {
        self.notify.notify_waiters();
    }
}

impl WarpRunner {
    pub fn init() -> Self {
        Self {
            notify: Arc::new(Notify::new()),
            ran_once: false,
        }
    }

    // spawns a thread which will terminate when WarpRunner is dropped
    pub fn run(&mut self, tx: UnboundedSender<WarpEvent>, rx: WarpCmdRx) {
        if self.ran_once {
            panic!("WarpRunner called run() multiple times");
        }
        self.ran_once = true;

        let tesseract = match Tesseract::from_file(DEFAULT_PATH.join(".keystore")) {
            Ok(tess) => tess,
            Err(_) => {
                //doesnt exist so its set
                let tess = Tesseract::default();
                tess.set_file(DEFAULT_PATH.join(".keystore"));
                tess.set_autosave();
                tess
            }
        };

        let (account, messaging, storage) = match warp::async_block_in_place_uncheck(
            warp_initialization(DEFAULT_PATH.clone(), tesseract.clone(), false),
        ) {
            Ok((i, c, s)) => (Account(i.clone()), Messaging(c.clone()), Storage(s.clone())),
            Err(_e) => todo!(),
        };

        let notify = self.notify.clone();
        tokio::spawn(async move {
            // todo: register for events from warp

            // this was the only way to get a mutable static variable. but this channel should only be read here.
            let mut rx = rx.lock().await;

            loop {
                tokio::select! {
                    // RayGun events
                    // MultiPass events
                    // ect
                    opt = rx.recv() => match opt {
                        Some(cmd) => todo!("handle cmd"),
                        None => break,
                    },
                    _ = notify.notified() => break,
                }
            }
        });
    }
}

async fn warp_initialization(
    path: PathBuf,
    tesseract: Tesseract,
    experimental: bool,
) -> Result<(Box<dyn MultiPass>, Box<dyn RayGun>, Box<dyn Constellation>), warp::error::Error> {
    let config = MpIpfsConfig::production(&path, experimental);

    let account = warp_mp_ipfs::ipfs_identity_persistent(config, tesseract, None)
        .await
        .map(|mp| Box::new(mp) as Box<dyn MultiPass>)?;

    let storage = warp_fs_ipfs::IpfsFileSystem::<warp_fs_ipfs::Persistent>::new(
        account.clone(),
        Some(FsIpfsConfig::production(&path)),
    )
    .await
    .map(|ct| Box::new(ct) as Box<dyn Constellation>)?;

    let messaging = warp_rg_ipfs::IpfsMessaging::<Persistent>::new(
        Some(RgIpfsConfig::production(&path)),
        account.clone(),
        Some(storage.clone()),
        None,
    )
    .await
    .map(|rg| Box::new(rg) as Box<dyn RayGun>)?;

    Ok((account, messaging, storage))
}

#[derive(Clone)]
pub struct Account(pub Box<dyn MultiPass>);

impl Deref for Account {
    type Target = Box<dyn MultiPass>;
    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl DerefMut for Account {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.0
    }
}

impl PartialEq for Account {
    fn eq(&self, other: &Self) -> bool {
        self.0.id() == other.0.id()
    }
}

#[derive(Clone)]
pub struct Storage(pub Box<dyn Constellation>);

impl Deref for Storage {
    type Target = Box<dyn Constellation>;
    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl DerefMut for Storage {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.0
    }
}

impl PartialEq for Storage {
    fn eq(&self, other: &Self) -> bool {
        self.0.id() == other.0.id()
    }
}

#[derive(Clone)]
pub struct Messaging(Box<dyn RayGun>);

impl Deref for Messaging {
    type Target = Box<dyn RayGun>;
    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl DerefMut for Messaging {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.0
    }
}

impl PartialEq for Messaging {
    fn eq(&self, other: &Self) -> bool {
        self.0.id() == other.0.id()
    }
}
