use derive_more::Display;
use futures::channel::oneshot;
use uuid::Uuid;
use warp::{blink::AudioDeviceConfig, crypto::DID};

use crate::warp_runner::Calling;

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
    #[display(fmt = "SilenceCall")]
    SilenceCall {
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "UnsilenceCall")]
    UnsilenceCall {
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "AdjustVolume")]
    AdjustVolume {
        user: DID,
        volume: f32,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "SetMicrophone")]
    SetMicrophone {
        device_name: String,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "SetSpeaker")]
    SetSpeaker {
        device_name: String,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "StartRecording")]
    StartRecording {
        output_dir: String,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "StopRecording")]
    StopRecording {
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "GetAudioDeviceConfig")]
    GetAudioDeviceConfig {
        rsp: oneshot::Sender<Result<Box<dyn AudioDeviceConfig>, warp::error::Error>>,
    },
    #[display(fmt = "SetEchoCancellation")]
    SetEchoCancellation {
        flag: bool,
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
        BlinkCmd::SilenceCall { rsp } => {
            let _ = rsp.send(blink.silence_call().await);
        }
        BlinkCmd::UnsilenceCall { rsp } => {
            let _ = rsp.send(blink.unsilence_call().await);
        }
        BlinkCmd::AdjustVolume { user, volume, rsp } => {
            let _ = rsp.send(blink.set_peer_audio_gain(user, volume).await);
        }
        BlinkCmd::SetMicrophone { device_name, rsp } => {
            let mut audio_config = blink.get_audio_device_config().await;
            audio_config.set_microphone(&device_name);
            let _ = rsp.send(blink.set_audio_device_config(audio_config).await);
        }
        BlinkCmd::SetSpeaker { device_name, rsp } => {
            let mut audio_config = blink.get_audio_device_config().await;
            audio_config.set_speaker(&device_name);
            let _ = rsp.send(blink.set_audio_device_config(audio_config).await);
        }
        BlinkCmd::StartRecording { output_dir, rsp } => {
            let _ = rsp.send(blink.record_call(&output_dir).await);
        }
        BlinkCmd::StopRecording { rsp } => {
            let _ = rsp.send(blink.stop_recording().await);
        }
        BlinkCmd::GetAudioDeviceConfig { rsp } => {
            let _ = rsp.send(Ok(blink.get_audio_device_config().await));
        }
        BlinkCmd::SetEchoCancellation { flag, rsp } => {
            if flag {
                let _ = rsp.send(blink.enable_automute());
            } else {
                let _ = rsp.send(blink.disable_automute());
            }
        }
    }
}
