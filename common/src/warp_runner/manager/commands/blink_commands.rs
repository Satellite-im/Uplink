use derive_more::Display;
use futures::channel::oneshot;
use uuid::Uuid;
use warp::crypto::DID;

use crate::warp_runner::Calling;

pub struct Devices {
    pub available_devices: Vec<String>,
    pub selected: Option<String>,
}

#[derive(Display)]
pub enum BlinkCmd {
    #[display(fmt = "OfferCall")]
    OfferCall {
        conversation_id: Uuid,
        participants: Vec<DID>,
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
    #[display(fmt = "AdjustVolume")]
    AdjustVolume {
        user: DID,
        volume: f32,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "GetAllMicrophones")]
    GetAllMicrophones {
        rsp: oneshot::Sender<Result<Devices, warp::error::Error>>,
    },
    #[display(fmt = "SetMicrophone")]
    SetMicrophone {
        device_name: String,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "GetAllSpeakers")]
    GetAllSpeakers {
        rsp: oneshot::Sender<Result<Devices, warp::error::Error>>,
    },
    #[display(fmt = "SetSpeaker")]
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
            rsp,
        } => {
            let _ = rsp.send(blink.offer_call(Some(conversation_id), participants).await);
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
        BlinkCmd::AdjustVolume { user, volume, rsp } => {
            let _ = rsp.send(blink.set_peer_audio_gain(user, volume).await);
        }
        BlinkCmd::GetAllMicrophones { rsp } => {
            let audio_config = blink.get_audio_device_config().await;
            let selected = audio_config.microphone_device_name();
            let result = audio_config
                .get_available_microphones()
                .map(|available_devices| Devices {
                    available_devices,
                    selected,
                })
                .map_err(warp::error::Error::from);
            let _ = rsp.send(result);
        }
        BlinkCmd::SetMicrophone { device_name, rsp } => {
            let mut audio_config = blink.get_audio_device_config().await;
            audio_config.set_microphone(&device_name);
            let _ = rsp.send(blink.set_audio_device_config(audio_config).await);
        }
        BlinkCmd::GetAllSpeakers { rsp } => {
            let audio_config = blink.get_audio_device_config().await;
            let selected = audio_config.speaker_device_name();
            let result = audio_config
                .get_available_speakers()
                .map(|available_devices| Devices {
                    available_devices,
                    selected,
                })
                .map_err(warp::error::Error::from);
            let _ = rsp.send(result);
        }
        BlinkCmd::SetSpeaker { device_name, rsp } => {
            let mut audio_config = blink.get_audio_device_config().await;
            audio_config.set_speaker(&device_name);
            let _ = rsp.send(blink.set_audio_device_config(audio_config).await);
        }
    }
}
