use futures::channel::oneshot;
use warp::tesseract::Tesseract;

use super::Account;

#[derive(Debug)]
pub enum TesseractCmd {
    KeyExists {
        key: String,
        rsp: oneshot::Sender<bool>,
    },
    Unlock {
        passphrase: String,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
}

#[derive(Debug)]
pub enum MultiPassCmd {
    CreateIdentity {
        username: String,
        passphrase: String,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
}

pub async fn handle_tesseract_cmd(cmd: TesseractCmd, tesseract: &mut Tesseract) {
    match cmd {
        TesseractCmd::KeyExists { key, rsp } => {
            let res = tesseract.exist(&key);
            let _ = rsp.send(res);
        }
        TesseractCmd::Unlock { passphrase, rsp } => {
            let r = match tesseract.unlock(passphrase.as_bytes()) {
                Ok(_) => Ok(()),
                Err(e) => Err(e),
            };
            let _ = rsp.send(r);
        }
    }
}

pub async fn handle_multipass_cmd(
    cmd: MultiPassCmd,
    tesseract: &mut Tesseract,
    account: &mut Account,
) {
    match cmd {
        MultiPassCmd::CreateIdentity {
            username,
            passphrase,
            rsp,
        } => {
            if let Err(e) = tesseract.unlock(passphrase.as_bytes()) {
                let _ = rsp.send(Err(e));
                return;
            }
            let r = match account.create_identity(Some(&username), None).await {
                Ok(_) => Ok(()),
                Err(e) => Err(e),
            };
            let _ = rsp.send(r);
        }
    }
}
