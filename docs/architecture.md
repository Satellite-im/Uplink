##  Uplink Architecture
- This document should serve as a high-level guide to the Uplink architecture and explain various ways to add to the application
---

## Background
- The Uplink repository consists of two `Cargo` projects: `kit` (a library) and `uplink` (the executable).  
- Uplink relies on [Warp](https://github.com/Satellite-im/Warp) and [Dioxus](https://github.com/DioxusLabs/dioxus). It is assumed the reader is familiar with the [Dioxus Documentation](https://dioxuslabs.com/guide/). 
- At a high level, Warp sends messages (it does much more), while Uplink is just the UI. Sending and receiving messages is asynchronous, and Uplink has a separate module to handle this: `warp_runner`. All the data for the Uplink UI is contained in a `State` struct. Changing the `State` struct drives the UI. When `warp_runner` handles an event from `Warp`, `State` is modified, and the entire UI is re-rendered.   

## Running the Application
- `uplink --help`
- specify a custom folder for `.uplink` with `--path`. `Warp` data is stored in `.uplink/.warp`. The UI is saved in `.uplink/state.json`. It doesn't contain much data - just `Uuid`s of conversations which should go in the sidebar, and other UI-specific things which can't be loaded by `Warp`. 
- use different logger profiles using subcommands. `debug` and `trace` are common choices. 

## UI Design
- the `kit` project contains the following modules
    + `elements`: correspond to HTML elements such as `input`, `button`, etc
    + `components`: are made up of elements, adding additional features
    + `layout`: are made up of components and elements. 
- the `uplink` project contains `components` and `layout` modules, which have the same meaning as in `kit`, with the following exception: modules in `uplink` can modify `State`. 
- use `logger::trace` to track when elements render
- get a hook for `State` via `use_shared_state`—no need to pass it in Props. 

## Starting the UI
- in `main.rs`, there is a call to `dioxus_desktop::launch_cfg`. It is passed a `bootstrap` element, which is rendered first. 
- Uplink needs to start `warp_runner` from within a `Tokio` runtime. That runtime isn't available until `dioxus_desktop::launch_cfg` is called. We don't want to restart `warp_runner` when the UI updates, so the `bootstrap` Element ensures this only happens once. 
- next `auth_page_manager` is rendered. `Warp` requires a user account. Until an account is created, the user data can't be decrypted and loaded. `auth_page_manager` uses the `auth_wrapper` element to handle user authentication and account creation. When done, `app_bootstrap` is rendered. 
- The global `State` variable drives the Uplink UI. It is initialized via `use_shared_state_provider`. We don't want this variable to be re-loaded every time the app updates, so `app_bootstrap` is used to initialize state. 
- finally, `app` is rendered. All the global channels are polled here, each with their own `use_future`. 
    + conversations are loaded from warp and added to `State`
    + friends are loaded from the warp and added to `State`
    + warp events are passed to `State::process_warp_event`
    + after all the `use_future`s, `cx.render()` is called with the various parts of the page.

## Global Variables
- Uplink uses global variables to do some essential things. They are all in `main.rs`. 
- `STATIC_ARGS` is for constant variables which may be affected by command line options
- the rest of the variables are channels. 

## Global Channels
- `WARP_CMD_CH`: used to communicate with `warp_runner`. Rather than block the UI while `Warp` performs a task, `warp_runner` receives commands via the channel and responds via a oneshot channel. `WARP_CMD_CH.tx` is used from within a Dioxus Element, inside a `use_future` or a `use_coroutine`. 
- `WARP_EVENT_CH`: the `app` Element from `main.rs` reads events from this channel and updates `State` accordingly. 
- `WINDOW_CMD_CH`: if Uplink spawns a child window, it is controlled via this channel. Commands are passed to the `window_manager` module, which, at a minimum, allows for closing the window in response to a UI event such as a button press. 

## warp_runner::WarpRunner
- provides access to `RayGun`, `MultiPass`, and `Tesseract` via the `WarpCmd` struct. Commands contain a oneshot channel for returning the result. `WARP_CMD_CH` is used to send `WarpCmd`s to `WarpRunner`.   
- notifies Uplink of Warp events via the `WarpEvent` struct. ex: friend requests and incoming messages. Note that a Warp event may not be in a format usable by the UI, and converting the event may require Warp. `warp_runner::ui_adapter` provides utilities for converting Warp events into something usable by the UI. 
- `WarpRunner` automatically shuts down all tasks using `tokio::notify` and a `Drop` implementation.
- all of the events/commands are processed inside of a `loop { select!{...} }`

## Examples

### Sending Warp commands
- `ui/src/components/friends/incoming_requests/mod.rs` displays a list of incoming friend requests. The user can accept or reject a request. When this happens, Warp needs to be notified. 
- `use_coroutine` provides a channel
- on button press (accept/reject), send a command to the coroutine
- clone `WARP_CMD_CH.tx` and write the command to the channel. 


### Spawning a child window
- `ui/src/components/media/player.rs` has an `onpress` event which does the following
    - uses a Dioxus DesktopContext to create a new window
        - passes in a `WindowDropHandler` as a prop. This struct ensures a close command is written to the `WINDOW_CMD_CH` when the window closes. 
    - gets the window ID
    - saves the window ID in State. State will now know which window to close when it receives a command. Unfortunately, we don't know the window ID until after the window is created, so we can't just have the `WindowDropHandler` send the WindowID in the channel. 
- look in the `use_future` in `main.rs` to see how the command is handled. 

### Ask Warp for something new
- this requires adding a command to `WarpCmd`, in `ui/src/warp_runner/mod.rs`. 
- handle the command in `command.rs`. ex: add an enumeration to `RayGunCmd` and manage it in the `manager::commands::raygun_command` module. 
- invoke the command from the UI by writing to `WARP_CMD_CH.tx` (demonstrated in a previous example). 

### Handle a new event from Warp
- add an enumeration to `WarpEvent` (located in `warp_runner.rs`)
- in `warp_runner/manager/mod.rs`, in the `run` function, write the new event to the `WarpEventTx` channel for one of the following reasons
    - in response to an event received via the `multipass_stream`
    - in response to an event received via the `raygun_stream`
    - in response to a new conversation message received by the `conversation_manager`
    - in response to a command received over the `WarpCmdRx` channel. 
- in `ui/src/state/mod.rs`, in `State::process_warp_event`, add handling for the new event. 
