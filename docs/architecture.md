##  Uplink Architecture
- This document should serve as a high level guide to the Uplink architecture and explain various ways to add to the application
---

## Background
- The Uplink repository consists of two `Cargo` projects: `kit` (a library) and `ui` (the executable).  
- Uplink relies on [Warp](https://github.com/Satellite-im/Warp) and [Dioxus](https://github.com/DioxusLabs/dioxus). It is assumed the reader is familiar with the [Dioxus Documentation](https://dioxuslabs.com/guide/). 
- At a high level, Warp is used to send messages (it does much more) while Uplink is just the UI. Sending and receiving messages is asynchronous, and Uplink has a separate module to handle this: `warp_runner`. All the data for the Uplink UI is contained in a `State` struct. Changing the `State` struct drives the UI. When `warp_runner` handles an event from `Warp`, `State` is modified and the entire UI is re-rendered.   

## Running the Application
- `ui --help`
- specify a custom folder for `.uplink` with `--path`. `Warp` data is stored in `.uplink/.warp`. The UI is saved in `.uplink/state.json`. It doesn't contain much data - just `Uuid`s of conversations which should go in the sidebar, and other UI specific things which can't be loaded by `Warp`. 
- use different logger profile using subcommand. `debug` and `trace` are common choices. 

## UI Design
- todo: elements, components, layouts ; kit and ui both follow that design
- todo: ui modifies state while kit doesn't 
- use `logger::trace` to track when elements render
- get a hook for `State` via `use_shared_state`. no need to pass it in Props. 

## Starting the UI
- in `main.rs` there is a call to `dioxus_desktop::launch_cfg`. It is passed a `bootstrap` element, which is rendered first. 
- Uplink needs to start `warp_runner` from within a `Tokio` runtime. That runtime isn't available until `dioxus_desktop::launch_cfg` is called. We don't want to restart `warp_runner` when the UI updates, so the `bootstrap` Element is used to ensure this only happens once. 
- next `auth_page_manager` is rendered. `Warp` requires a user account. Until an account is created, the user data can't be decrypted and loaded. `auth_page_manager` uses the `auth_wrapper` element to handle user authentication and account creation. when doe, `app_bootstrap` is rendered. 
- The uplink UI is driven by the global `State` variable. It is initialized via `use_shared_state_provider`. We don't want this variable to be re-loaded every time the app updates, so `app_bootstrap` is used to initialize state. 
- finally `app` is rendered. All the global channels are polled here, each with their own `use_future`. 
    + conversations are loaded from warp and added to `State`
    + friends are loaded from warp and added to `State`
    + warp events are passed to `State::process_warp_event`
    + after all the `use_future`s, `cx.render()` is called with the various parts of the page.

## Global Variables
- Uplink uses global variables to do some important things. They are all in `main.rs`. 
- `STATIC_ARGS` is for constant variables which may be affected by command line options
- `UPLINK_ROUTES` is for use with Dioxus Router. 
- the rest of the variables are channels. 

## Global Channels
- `WARP_CMD_CH`: used to communicate with `warp_runner`. Rather than block the UI while `Warp` performs a task, `warp_runner` receives commands via the channel and responds via a oneshot channel. `WARP_CMD_CH.tx` is used from within a Dioxus Element, inside of a `use_future` or a `use_coroutine`. 
- `WARP_EVENT_CH`: the `app` Element from `main.rs` reads events from this channel and updates `State` accordingly. 
- `WINDOW_CMD_CH`: if Uplink spawns a child window, it is controlled via this channel. Commands are passed to the `window_manager` module, which at a minimum allows for closing the window in response to a UI event such as a button press. 

## warp_runner::WarpRunner
- provides access to `RayGun`, `MultiPass`, and `Tesseract` via the `WarpCmd` struct. Commands contain a oneshot channel for returning the result.  
- notifies Uplink of Warp events via the `WarpEvent` struct. ex: friend requests and incoming messages. Note that a Warp event may not be in a format usable by the UI, and converting the event may require Warp. `warp_runner::ui_adapter` provides utilities for converting Warp events into something usable by the UI. 
- `WarpRunner` automatically shuts down all threads using `tokio::notify` and a `Drop` implementation.
- all of the events/commands are processed inside of a `loop { select!{...} }`. It's messy but this allows all the different functions to use the same mutable references to `RayGun`, `MultiPass`, and `Tesseract`. 