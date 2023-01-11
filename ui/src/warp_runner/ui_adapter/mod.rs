//! an event from Warp isn't necessarily what the UI needs to display. and the UI doesn't have access to RayGun, MultiPass, ect. As a result,
//! a translation must be performed by WarpRunner.
//!

use warp::{crypto::DID, multipass::MultiPassEventKind};

use crate::state;

pub enum RayGunEvent {
    None,
}

pub enum MultiPassEvent {
    FriendRequestReceived(state::Identity),
    FriendRequestSent(state::Identity),
}

// todo: put account and messaging in a module
pub async fn convert_multipass_event(
    event: warp::multipass::MultiPassEventKind,
    account: &mut super::Account,
    messaging: &mut super::Messaging,
) -> MultiPassEvent {
    // todo: make this a function
    let did_to_identity = |did: DID| async {
        let warp_identity = account
            .get_identity(did.into())
            .await
            .expect("could not get warp identity");
        state::Identity::from(
            warp_identity
                .first()
                .cloned()
                .expect("could not get warp identity"),
        )
    };

    match event {
        MultiPassEventKind::FriendRequestSent { to } => {
            let identity = did_to_identity(to).await;
            MultiPassEvent::FriendRequestSent(identity)
        }
        MultiPassEventKind::FriendRequestReceived { from } => {
            let identity = did_to_identity(from).await;
            MultiPassEvent::FriendRequestReceived(identity)
        }
        _ => todo!(),
    }
}

pub async fn convert_raygun_event(
    event: warp::raygun::RayGunEventKind,
    account: &mut super::Account,
    messaging: &mut super::Messaging,
) -> RayGunEvent {
    todo!()
}
