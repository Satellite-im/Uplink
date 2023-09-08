use derive_more::Display;
use futures::channel::oneshot;
use uuid::Uuid;
use warp::{blink::AudioCodec, crypto::DID};

use crate::warp_runner::Calling;

type DeviceResult = (
    Result<std::vec::Vec<std::string::String>, warp::error::Error>,
    std::option::Option<std::string::String>,
);

#[derive(Display)]
pub enum BlinkCmd {
    #[display(fmt = "OfferCall")]
    OfferCall {
        conversation_id: Uuid,
        participants: Vec<DID>,
        webrtc_codec: AudioCodec,
        rsp: oneshot::Sender<Result<Uuid, warp::error::Error>>,
    },
    #[display(fmt = "AnswerCall")]
    AnswerCall {
        call_id: Uuid,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "RejectCall")]
    RejectCall {
        call_id: Uuid,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "LeaveCall")]
    LeaveCall {
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "MuteSelf")]
    MuteSelf {
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "UnmuteSelf")]
    UnmuteSelf {
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "GetAllMicrophones")]
    GetAllMicrophones { rsp: oneshot::Sender<DeviceResult> },
    #[display(fmt = "GetAllMicrophones")]
    SetMicrophone {
        device_name: String,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "GetAllMicrophones")]
    GetAllSpeakers { rsp: oneshot::Sender<DeviceResult> },
    #[display(fmt = "GetAllMicrophones")]
    SetSpeaker {
        device_name: String,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
}

pub async fn handle_blink_cmd(cmd: BlinkCmd, blink: &mut Calling) {
    match cmd {
        BlinkCmd::OfferCall {
            conversation_id,
            participants,
            webrtc_codec,
            rsp,
        } => {
            let _ = rsp.send(
                blink
                    .offer_call(Some(conversation_id), participants, webrtc_codec)
                    .await,
            );
        }
        BlinkCmd::AnswerCall { call_id, rsp } => {
            let _ = rsp.send(blink.answer_call(call_id).await);
        }
        BlinkCmd::RejectCall { call_id, rsp } => {
            let _ = rsp.send(blink.reject_call(call_id).await);
        }
        BlinkCmd::LeaveCall { rsp } => {
            let _ = rsp.send(blink.leave_call().await);
        }
        BlinkCmd::MuteSelf { rsp } => {
            let _ = rsp.send(blink.mute_self().await);
        }
        BlinkCmd::UnmuteSelf { rsp } => {
            let _ = rsp.send(blink.unmute_self().await);
        }
        BlinkCmd::GetAllMicrophones { rsp } => {
            let _ = rsp.send((
                blink.get_available_microphones().await,
                blink.get_current_microphone().await,
            ));
        }
        BlinkCmd::SetMicrophone { device_name, rsp } => {
            let _ = rsp.send(blink.select_microphone(&device_name).await);
        }
        BlinkCmd::GetAllSpeakers { rsp } => {
            let _ = rsp.send((
                blink.get_available_speakers().await,
                blink.get_current_speaker().await,
            ));
        }
        BlinkCmd::SetSpeaker { device_name, rsp } => {
            let _ = rsp.send(blink.select_speaker(&device_name).await);
        }
    }
}
