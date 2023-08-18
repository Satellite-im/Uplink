use super::*;

use crate::utils::auto_updater::DownloadState;
use common::state::ui::WindowMeta;
use common::state::State;
use common::STATIC_ARGS;
use dioxus_desktop::use_window;
use overlay::make_config;
use overlay::OverlayDom;
use warp::multipass;

pub(crate) fn use_boostrap(cx: &ScopeState, identity: &multipass::identity::Identity) {
    cx.use_hook(|| {
        let mut state = State::load();

        if STATIC_ARGS.use_mock {
            assert!(state.initialized);
        } else {
            state.set_own_identity(identity.clone().into());
        }

        let desktop = use_window(cx);
        // TODO: This overlay needs to be fixed in windows
        if cfg!(not(target_os = "windows")) && state.configuration.general.enable_overlay {
            let overlay_test = VirtualDom::new(OverlayDom);
            let window = desktop.new_window(overlay_test, make_config());
            state.ui.overlays.push(window);
        }

        let size = desktop.webview.inner_size();
        // Update the window metadata now that we've created a window
        let window_meta = WindowMeta {
            focused: desktop.is_focused(),
            maximized: desktop.is_maximized(),
            minimized: desktop.is_minimized(),
            minimal_view: size.width < 1200, // todo: why is it that on Linux, checking if desktop.inner_size().width < 600 is true?
        };
        state.ui.metadata = window_meta;

        use_shared_state_provider(cx, || state);
        use_shared_state_provider(cx, DownloadState::default);

        // Now turn on the warp runner and save it to the hook so it doesn't get dropped
        let mut runner = warp_runner::WarpRunner::new();
        runner.run();
        runner
    });
}
