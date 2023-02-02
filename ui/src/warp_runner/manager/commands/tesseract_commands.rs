use derive_more::Display;
use futures::channel::oneshot;

#[derive(Display)]
pub enum TesseractCmd {
    #[display(fmt = "KeyExists {{ {key} }} ")]
    KeyExists {
        key: String,
        rsp: oneshot::Sender<bool>,
    },
}
