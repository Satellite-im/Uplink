use derive_more::Display;
use futures::channel::oneshot::{self};
use tokio::sync::mpsc::UnboundedReceiver;
use uuid::Uuid;
use warp::logging::tracing::log;
use warp::{
    blink::{AudioDeviceConfig, AudioTestEvent},
    crypto::DID,
};

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
    #[display(fmt = "TestSpeaker")]
    TestSpeaker {
        rsp: oneshot::Sender<UnboundedReceiver<AudioTestEvent>>,
    },
    #[display(fmt = "TestMicrophone")]
    TestMicrophone {
        rsp: oneshot::Sender<UnboundedReceiver<AudioTestEvent>>,
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
            let result = match blink.get_audio_device_config().await {
                Ok(mut audio_config) => {
                    audio_config.set_microphone(&device_name);
                    blink.set_audio_device_config(audio_config).await
                }
                Err(e) => Err(e),
            };
            let _ = rsp.send(result);
        }
        BlinkCmd::SetSpeaker { device_name, rsp } => {
            let result = match blink.get_audio_device_config().await {
                Ok(mut audio_config) => {
                    audio_config.set_speaker(&device_name);
                    blink.set_audio_device_config(audio_config).await
                }
                Err(e) => Err(e),
            };
            let _ = rsp.send(result);
        }
        BlinkCmd::StartRecording { output_dir, rsp } => {
            let _ = rsp.send(blink.record_call(&output_dir).await);
        }
        BlinkCmd::StopRecording { rsp } => {
            let _ = rsp.send(blink.stop_recording().await);
        }
        BlinkCmd::GetAudioDeviceConfig { rsp } => {
            let _ = rsp.send(blink.get_audio_device_config().await);
        }
        BlinkCmd::SetEchoCancellation { flag, rsp } => {
            if flag {
                let _ = rsp.send(blink.enable_automute());
            } else {
                let _ = rsp.send(blink.disable_automute());
            }
        }
        BlinkCmd::TestSpeaker { rsp } => {
            match blink.get_audio_device_config().await {
                Ok(mut audio_config) => {
                    audio_config.set_speaker(&audio_config.get_available_speakers().unwrap()[0]);
                    let _ = audio_config
                        .test_speaker(rsp)
                        .map_err(warp::error::Error::Any);
                }
                Err(e) => {
                    log::debug!("speaker testing fail {:}", e);
                }
            };
        }
        BlinkCmd::TestMicrophone { rsp } => {
            match blink.get_audio_device_config().await {
                Ok(mut audio_config) => {
                    audio_config
                        .set_microphone(&audio_config.get_available_microphones().unwrap()[0]);
                    audio_config.set_speaker(&audio_config.get_available_speakers().unwrap()[0]);
                    let _ = audio_config
                        .test_microphone(rsp)
                        .map_err(warp::error::Error::Any);
                }
                Err(e) => {
                    log::debug!("microphone testing fail {:}", e);
                }
            };
        }
    }
}
