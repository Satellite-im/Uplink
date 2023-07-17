use warp::{
    blink::BlinkEventKind,
    logging::tracing::log,
    multipass::MultiPassEventKind,
    raygun::{MessageEventKind, RayGunEventKind},
};

use crate::{
    warp_runner::{
        conv_stream,
        manager::commands::handle_blink_cmd,
        ui_adapter::{self, did_to_identity, MultiPassEvent},
        WarpCmd, WarpEvent,
    },
    WARP_EVENT_CH,
};

use super::{
    commands::{
        handle_constellation_cmd, handle_multipass_cmd, handle_other_cmd, handle_raygun_cmd,
    },
    MultiPassCmd,
};

pub async fn handle_multipass_event(
    evt: Option<MultiPassEventKind>,
    warp: &mut super::Warp,
) -> Result<(), ()> {
    let evt = match evt {
        Some(e) => e,
        None => return Ok(()),
    };
    log::debug!("received multipass event: {:?}", &evt);
    let warp_event_tx = WARP_EVENT_CH.tx.clone();
    match ui_adapter::convert_multipass_event(evt, &mut warp.multipass, &mut warp.raygun).await {
        Ok(evt) => {
            if warp_event_tx.send(WarpEvent::MultiPass(evt)).is_err() {
                log::error!("failed to send warp_event");
                return Err(());
            }
        }
        Err(e) => {
            log::error!("failed to convert multipass event: {}", e);
        }
    }

    Ok(())
}

pub async fn handle_raygun_event(
    evt: Option<RayGunEventKind>,
    warp: &mut super::Warp,
    stream_manager: &mut conv_stream::Manager,
) -> Result<(), ()> {
    let evt = match evt {
        Some(e) => e,
        None => return Ok(()),
    };
    log::debug!("received raygun event: {:?}", &evt);
    let warp_event_tx = WARP_EVENT_CH.tx.clone();
    match ui_adapter::convert_raygun_event(
        evt,
        stream_manager,
        &mut warp.multipass,
        &mut warp.raygun,
    )
    .await
    {
        Ok(evt) => {
            if warp_event_tx.send(WarpEvent::RayGun(evt)).is_err() {
                log::error!("failed to send warp_event");
                return Err(());
            }
        }
        Err(e) => {
            log::error!("failed to convert raygun event: {}", e);
        }
    }

    Ok(())
}

pub async fn handle_message_event(
    evt: Option<MessageEventKind>,
    warp: &mut super::Warp,
) -> Result<(), ()> {
    let msg = match evt {
        Some(e) => e,
        None => return Ok(()),
    };
    let warp_event_tx = WARP_EVENT_CH.tx.clone();
    match ui_adapter::convert_message_event(msg, &mut warp.multipass, &mut warp.raygun).await {
        Ok(evt) => {
            if warp_event_tx.send(WarpEvent::Message(evt)).is_err() {
                log::error!("failed to send warp_event");
                return Err(());
            }
        }
        Err(e) => {
            log::error!("failed to convert message event: {}", e);
        }
    }

    Ok(())
}

pub async fn handle_blink_event(evt: BlinkEventKind, warp: &mut super::Warp) -> anyhow::Result<()> {
    let warp_event_tx = WARP_EVENT_CH.tx.clone();
    warp_event_tx.send(WarpEvent::Blink(evt.clone()))?;

    if let BlinkEventKind::ParticipantLeft {
        call_id,
        peer_id: _,
    } = &evt
    {
        if warp
            .blink
            .current_call()
            .await
            .map(|call_info| &call_info.call_id() == call_id && call_info.participants().len() == 2)
            .unwrap_or(false)
        {
            if let Err(e) = warp.blink.leave_call().await {
                anyhow::bail!("failed to leave call: {e}")
            } else {
                warp_event_tx.send(WarpEvent::Blink(BlinkEventKind::ParticipantLeft {
                    call_id: *call_id,
                    peer_id: warp.multipass.get_own_identity().await?.did_key(),
                }))?;
            }
        }
    }

    Ok(())
}

pub async fn handle_warp_command(
    evt: Option<WarpCmd>,
    warp: &mut super::Warp,
    stream_manager: &mut conv_stream::Manager,
) -> Result<(), ()> {
    let cmd = match evt {
        Some(e) => e,
        None => return Ok(()),
    };
    log::debug!("WARP CMD: {}", &cmd);
    let warp_event_tx = WARP_EVENT_CH.tx.clone();
    match cmd {
        WarpCmd::Other(cmd) => {
            // this one could be parallelized
            handle_other_cmd(cmd).await;
        }
        WarpCmd::Tesseract(_cmd) => {
            // not accepted at this stage of the program. do nothing and drop the rsp channel
        }
        WarpCmd::MultiPass(cmd) => {
            // if a command to block a user comes in, need to update the UI
            // todo: handle block events
            if let MultiPassCmd::Block { did, .. } = &cmd {
                if let Ok(ident) = did_to_identity(did, &warp.multipass).await {
                    if warp_event_tx
                        .send(WarpEvent::MultiPass(MultiPassEvent::Blocked(ident)))
                        .is_err()
                    {
                        log::error!("failed to send warp_event");
                        return Err(());
                    }
                }
            }
            if let MultiPassCmd::Unblock { did, .. } = &cmd {
                if let Ok(ident) = did_to_identity(did, &warp.multipass).await {
                    if warp_event_tx
                        .send(WarpEvent::MultiPass(MultiPassEvent::Unblocked(ident)))
                        .is_err()
                    {
                        log::error!("failed to send warp_event");
                        return Err(());
                    }
                }
            }
            handle_multipass_cmd(cmd, warp).await;
        }

        WarpCmd::RayGun(cmd) => {
            handle_raygun_cmd(cmd, stream_manager, &mut warp.multipass, &mut warp.raygun).await
        }

        WarpCmd::Constellation(cmd) => handle_constellation_cmd(cmd, &mut warp.constellation).await,
        WarpCmd::Blink(cmd) => handle_blink_cmd(cmd, &mut warp.blink).await,
    }
    Ok(())
}
