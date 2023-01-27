use futures::channel::oneshot;

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

// currently unused
pub async fn handle_tesseract_cmd(cmd: TesseractCmd, tesseract: &mut Tesseract) {
    match cmd {
        TesseractCmd::KeyExists { key, rsp } => {
            let res = tesseract.exist(&key);
            let _ = rsp.send(res);
        }
        TesseractCmd::Unlock { passphrase, rsp } => {
            let r = tesseract.unlock(passphrase.as_bytes());
            let _ = rsp.send(r);
        }
    }
}
