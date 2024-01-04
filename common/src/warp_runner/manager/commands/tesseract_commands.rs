use derive_more::Display;
use futures::channel::oneshot;
use warp::tesseract::Tesseract;

#[derive(Display)]
pub enum TesseractCmd {
    #[display(fmt = "AccountExists")]
    AccountExists { rsp: oneshot::Sender<bool> },
    #[display(fmt = "GetMnemonic")]
    GetMnemonic {
        rsp: oneshot::Sender<Result<String, warp::error::Error>>,
    },
}

impl std::fmt::Debug for TesseractCmd {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self}")
    }
}

pub fn handle_tesseract_cmd(cmd: TesseractCmd, tesseract: &Tesseract) {
    match cmd {
        TesseractCmd::GetMnemonic { rsp } => {
            let _ = rsp.send(tesseract.retrieve("mnemonic"));
        }
        _ => {}
    }
}
