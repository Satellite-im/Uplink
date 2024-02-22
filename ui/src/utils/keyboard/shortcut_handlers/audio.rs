use common::state::{Action, State};
use common::{
    state::{
        call::{ActiveCall, Call},
        ui::Layout,
    },
    warp_runner::{BlinkCmd, WarpCmd},
    WARP_CMD_CH,
};
use dioxus::prelude::*;
use futures::channel::oneshot;

use crate::components::media::calling::CallDialogCmd;

pub fn toggle_mute(state: UseSharedState<State>, cx: Scope) {
    // CallInfo::mute_self(CallInfo);
    let recording = use_ref(cx, || false);
    let call_state = use_shared_state::<Call>(cx).expect("call_state is None");
    if !call_state.read().self_muted {
        let ch: &Coroutine<CallDialogCmd> = use_coroutine(cx, |mut rx| {
            to_owned![state, recording];
            async move {
                let warp_cmd_tx = WARP_CMD_CH.tx.clone();

                let (tx, rx) = oneshot::channel();
                if let Err(e) = warp_cmd_tx.send(WarpCmd::Blink(BlinkCmd::MuteSelf { rsp: tx })) {
                    log::error!("failed to send blink command: {e}");
                }

                match rx.await {
                    Ok(_) => {
                        // disaster waiting to happen if State ever gets out of sync with blink.
                        state.write().mutate(Action::ToggleMute);
                    }
                    Err(e) => {
                        log::error!("warp_runner failed to mute self: {e}");
                    }
                }
            }
        });
    }
    if call_state.read().self_muted {
        let ch: &Coroutine<CallDialogCmd> = use_coroutine(cx, |mut rx| {
            to_owned![state, recording];
            async move {
                let warp_cmd_tx = WARP_CMD_CH.tx.clone();

                let (tx, rx) = oneshot::channel();
                if let Err(e) = warp_cmd_tx.send(WarpCmd::Blink(BlinkCmd::UnmuteSelf { rsp: tx })) {
                    log::error!("failed to send blink command: {e}");
                }

                match rx.await {
                    Ok(_) => {
                        // disaster waiting to happen if State ever gets out of sync with blink.
                        state.write().mutate(Action::ToggleMute);
                    }
                    Err(e) => {
                        log::error!("warp_runner failed to mute self: {e}");
                    }
                }
            }
        });
    }
}

pub fn toggle_deafen(state: UseSharedState<State>, cx: Scope) {
    let recording = use_ref(cx, || false);
    let call_state = use_shared_state::<Call>(cx).expect("call_state is None");

    if !call_state.read().self_muted {
        let ch: &Coroutine<CallDialogCmd> = use_coroutine(cx, |mut rx| {
            to_owned![state, recording];
            async move {
                let warp_cmd_tx = WARP_CMD_CH.tx.clone();

                let (tx, rx) = oneshot::channel();
                if let Err(e) = warp_cmd_tx.send(WarpCmd::Blink(BlinkCmd::SilenceCall { rsp: tx }))
                {
                    log::error!("failed to send blink command: {}", e);
                    return; // Return early to avoid further processing
                }

                match rx.await {
                    Ok(_) => {
                        state.write().mutate(Action::ToggleMute);
                    }
                    Err(e) => {
                        log::error!("warp_runner failed to mute self: {}", e);
                    }
                }
            }
        });
    } else if call_state.read().self_muted {
        let ch: &Coroutine<CallDialogCmd> = use_coroutine(cx, |mut rx| {
            to_owned![state, recording];
            async move {
                let warp_cmd_tx = WARP_CMD_CH.tx.clone();

                let (tx, rx) = oneshot::channel();
                if let Err(e) =
                    warp_cmd_tx.send(WarpCmd::Blink(BlinkCmd::UnsilenceCall { rsp: tx }))
                {
                    log::error!("failed to send blink command: {}", e);
                    return; // Return early to avoid further processing
                }

                match rx.await {
                    Ok(_) => {
                        state.write().mutate(Action::ToggleMute);
                    }
                    Err(e) => {
                        log::error!("warp_runner failed to mute self: {}", e);
                    }
                }
            }
        });
    }
}
