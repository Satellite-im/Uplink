use tokio::sync::oneshot;
use warp::tesseract::Tesseract;

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

pub fn handle_tesseract_cmd(tesseract: &mut Tesseract, cmd: TesseractCmd) {
    match cmd {
        TesseractCmd::KeyExists { key, rsp } => {
            let res = tesseract.exist(&key);
            let _ = rsp.send(res);
        }
        TesseractCmd::Unlock { passphrase, rsp } => {
            let res = tesseract.unlock(passphrase.as_bytes());
            let _ = tesseract.save();
            let _ = rsp.send(res);
        }
    }
}
