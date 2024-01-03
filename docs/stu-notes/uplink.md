> A Tour of Uplink
- Note that `uplink` and `ui` may be used interchangeably in this document. 
---

# Quirks
- something called "clear css" is used. It removes the default styling for all html elements. If you add something to the UI and it doesn't display, this is why. Add the styling in the appropriate `.scss` file. 
- currently the CPU usage on linux is high, idling at about 100% of 1 CPU. I believe this either due to a render loop or is due to a bug in dioxus/wry/tao because a profiler (samply) revealed that most of the time was spent in these 3 functions: gtk_main_context_iteration > g_main_context_prepare > GL___poll > g_main_context_check. Using `top` on `blink-repl` (from the warp project) shows that warp is using something like 24% of 1 CPU, at least on startup. It's likely that the high CPU usage isn't due to warp/IPFS. 
- random crashes: usually caused by an out of date extension. also sometimes caused by Dioxus. We are using a fork of Dioxus because that allowed us to merge in some PRs (which are still pending in the Dioxus repository) that fixed some of the crashes we experienced. One particular crash was caused by using tokio in debug mode on windows because something caused a stack overflow. 

# Important parts of the app
- `ui/src/lib.rs > app_layout`
- `common/lib.rs`
- `common/src/state/mod.rs > mutate`
- `common/src/state/mod.rs > process_warp_events`
- `ui/src/lib.rs > app`, particularly `bootstrap::use_warp_runner`

# Repository Layout
- common
    - locales: `get_local_text(<key/value from locales>)` is used for text that will be displayed to the user. It allows the app to support multiple languages. 
    - src/language: sets up the language handling. uses the locales module
    - src/icons: makes the icons, created by the `icons` project, available to anyone who imports the `common` library. 
    - src/sounds: where the sounds live. 
    - src/state: the heart of state management. `ui` uses a `UseSharedState<State>` everywhere. most everything reads from and updates state. More on this later
    - src/testing: not sure if anyone still uses this. at one point there was a way to fill state with test data, for testing the UI. 
    - src/warp_runner: controls the structs which implement the various traits in `Warp`. The UI communicates with warp_runner via channels, defined in `lib.rs`. warp_runner is documented in docs/architecture.md.
    - `lib.rs`: defines some static channels - `WARP_CMD_CH` and `WARP_EVENT_CH`. Defines the configuration for `ui` - `STATIC_ARGS`. Defines the command line arguments for `ui` - `Args`. Also contains utility functions for getting the correct directory for images and extensions, which is platform specific. 
    - `sounds.rs`: suggest moving this to `src/sounds/mod.rs`. 
    - `upload_file_channel.rs`: channels used to upload a file. 
- docs
    - architecture.md: please read this. It explains kit and warp_runner, and tells you how to use the executable. 
- extension_example: Shows how to make an extension
- extensions
    - api.rs - seems to not be used. 
    - lib.rs - defines an `Extension` trait. Allows someone to create a shared library which exposes a C FFI that corresponds to the functions of the `Extension` trait. Note that Rust isn't guaranteed to have a stable memory layout between versions and `uplink` compares the version of Rust that it was compiled with to the version reported by the extension. `libloading` is used to load the share library into memory during runtime. Currently this is only used for emojis, and only to force the team to keep extensions working. The UI looks at `extension.details().location` to decide where to render an extension. for an example, see `ui/src/layouts/chats/presentation/chatbaar/mod.rs > get_chatbar` (search for `ui.extensions`). 
- icons: svg icons. i believe this came from `dioxus/heroicons` and was added to. There's  a VsCode extension to view them called "Svg Preview". 
- kit: explained in docs/architecture.md
- native_extensions: contains extensions developed by the Satellite team, such as the emoji extension. 
- ui
    - deb: used for building a .deb package
    - docs: outdated docs. can be ignored. should probably be deleted. 
    - extra: the resources directory. Contains images used by the app, `prism_langs` (a javascript library for highlighting code blocks), and some stuff needed for releasing software on MacOs and Windows. 
    - wix: used to generate the windows installer. 
    - src: is documented in more detail later on in this document. Each view needs its own section in this document. 
- utils: seems to be intended for utility scripts. 

# The Executable
- The executable, named `uplink`, is produced by the `ui` project. 
- `clap` was used, so you can use `--help`, same as most rust executables. 
- `env_logger` is used. you can prefix the executable with `RUST_LOG=uplink=debug,common=debug,kit=debug,warp_blink_wrtc=debug` for example. This is currently done by default if `RUST_LOG` isn't defined. Note that if you do this: `RUST_LOG=debug`, then the logs may be spammed by the `rust-ipfs` crate. 

# The .uplink Directory
- `uplink` persists data at `~/.uplink`. `warp` persists data at `~/.uplink/.warp`. you can find this in `common/src/lib.rs > STATIC_ARGS`. the contents of `.warp` are encrypted and require a password. 
- `uplink` persists state in `~/.uplink/.user/state.json`. State is serialized/deserialized using `Serde`. `#[serde(ignore)]` is used to annotate data that comes from warp, so friends and messages shouldn't be stored in `state.json`. `#[serde(default)]` is used to annotate new fields in the hopes that a software update wouldn't result in a user having a version of `state.json` that uplink doesn't know how to parse. 
- if you want to test multiple accounts on the same machine, `uplink` takes a `--path` argument, which can be used like this: `uplink --path=/tmp/warp1`. 

# Software Release
- note that released software is compiled with the `production_mode` feature, which tells the app to behave differently. 
    - on Windows, a GUI will be launched. otherwise uplink will be a console app. 
    - the resources are in an OS specific location instead of being assumed to be within the `Uplink` repository. 
## Location of Resources
- you can find this in `common/lib` in the `get_images_dir()` and `get_extras_dir()` functions.
- `ui/src/layouts/loading.rs` calls `utils::unzip_prism_langs()`, which will, for the first time `uplink` is run since installed, find the zipped resources and unzip them into the proper location. The zip file is created by the `build.rs` script. 
## Windows
- `ui/wix/main.wxs` is a wix file. `cargo-wix` is used to create a windows installer. note that wix requires declaring every single file to be included. It seemed like there might have been a way to use fragments to easily include an entire folder but i never got that working. Instead, large folders were zipped by a build script (see ui/build.rs > `zip_dir()`) and the zip file was included in the `.wxs` file. For wix documentation, see [here]( https://www.firegiant.com/wix/tutorial/). A github workflow is used to build the release. see `.github/workflows/buidl-release-windows.yml`. 
## Mac
- relevant files: `ui/extra/entitlements.plist` and `ui/extra/macos`. Also see the root `Makefile` and `.github/workflows/build-dmg-universal.yml`. 
## Linux
- relevant files: `build_linux_installer.sh`, `.github/workflows/build-release-linux.yml`, and `ui/deb`

# ui/src/main.rs and lib.rs
- the first line: `#![cfg_attr(feature = "production_mode", windows_subsystem = "windows")]` ensures when uplink is installed on windows and you launch the app, a terminal doesn't appear along with the app. 
- `uplink::main_lib()` is then called in main. This is needed for mobile releases. A different main function with different setup is needed for mobile builds, after which the original `main()` function needs to be called. 
- the entrypoint is `main_lib()`. 
- Dioxus comes with a router, for navigating between pages. But the router isn't started until the user logs in. The pages that come before that are/will be in `layouts/log_in`. Those pages also need to talk with warp_runner. warp_runner handles commands differently during the login process as well. See `common/src/warp_runner/mod.rs > handle_login()`. 
- the Dioxus router lets each route get wrapped in the same element. in this case it's `app_layout`. That function calls `use_app_coroutines()`, which handles initialization, receives events from `warp_runner`, and periodically updates the UI. 

# Views/Layouts
## chats
- see the README.md for more information. (ui/src/layouts/chats/README.md)
- the messages view has many nested functions but if you start reading at the top with `get_messages`, it isn't so bad. Things were done this way to wrap every sequence of messages that is from the same sender with a css class to "group" the messages. 
- As much as possible was moved out of state and into `chat/data`. the chats layout has its own `use_shared_state`s but still needs `state` for identity information, and to know which chat to display on startup. 
- the chats sidebar still relies on `state`. 
- having to pull data from both `state` and `ChatData` is far from perfect. `ChatData` was added during a refactor and it was too hard to get rid of `State` entirely because it was used everywhere, even though it's mostly used here for identities and knowing which conversations are in the sidebar and who is part of each conversation. 
- `presentation/chat/coroutines.rs` receives warp events and updates the current conversation accordingly. This departs from the design of using writes to `use_shared_state<State>` to drive the UI, and reasons for that may be gleaned from the last section of this document.
- scrolling has some tricky edge cases. The user can scroll up without making the IntersectionObserver fire. During this phase, we still want the "scroll to bottom" button to appear, and for incoming messages to not get rendered at the bottom of the view. To accomplish this, the `onscroll` event handler is used in conjunction with the IntersectionObserver. Another edge case to note is when a view is deemed empty because the message overflows the screen. This can happen if a message contains multiple image attachments. This is another reason to use the `oncscroll` event in conjunction with the IntersectionObserver. 
## storage
- this one was a test drive of clean arch, hence the `controller.rs` module within the `files_layout`. So far there hasn't been a need to change other parts of the codebase to match this style. Between storage, chats, and the rest of the app, there are 3 coding styles within uplink. 
- notable features include file upload via drag and drop and file upload via copy paste. 
- the `functions.rs` file seems like a utility file. It was a way to move code out of the function that returns an `Element`. 
- if you get stuck on something here, recommend asking Lucas. 
## settings
- pretty self explanatory. All the sub pages for `layouts/settings.rs` are in `components/settings/sub_pages`. These folders could be consolidated. 
## friends
- same deal as settings. 

# warp runner
- starts with `warp_runner/mod.rs > handle_login`. Once login succeeds, `manager::run()` is called, which lives in `warp_runner/manager/mod.rs`. 
- warp_runner obtains event streams from each trait object (raygun, multipass, blink) and polls them, along with the `warp_cmd_rx` channel, in a loop.
- warp runner commands are defined in `warp_runner/mod.rs > WarpCmd` and within `warp_runner/manager/commands`. 

# Tips on coding
- read the dioxus manual. even though Dioxus is now on 0.4, [this version of the docs](https://dioxuslabs.com/docs/0.3/guide/en/) is pretty good. 
- the `use_future` and `use_coroutine` functions within an `Element` can be quite large. To keep the function size small and readable, recommend making a separate `coroutines.rs` module for these functions. `futures.rs` would probably cause a naming conflict so I recommend putting both `use_future` and `use_coroutine` within a `coroutines.rs` file. 
- for `use_effect`, a `effects.rs` module will do. 
- a view may need its own structs. I recommend putting these within a `data` folder. Some other parts of the app add structs to `state` but if they aren't persisted in the `state.json` then I believe it more appropriate to move them out of the `common` crate. 
- it might have been helpful at some point to try to keep `use_shared_state` out of leaf elements as much as possible but i'm not sure. Dioxus won't re-render something if the props haven't changed. If data from `state` was extracted in the parent element and then passed to the child through props, maybe writes to state would cause fewer re-renders. It also might have made it easier to refactor state in the future. Of course it's too late now for that now and no one knew to do that at the beginning. 
- Dioxus 0.4 has a new thing called `Signal`, which may be able to help with performance. We have an attempt at something similar (I believe) with `common/src/state/mod.rs > state.scope_ids`. 

# History
- The initial idea (of the version of Uplink that was created at the start of 2023) was to store everything in state and make a "functional UI". Initially all conversations, messages, and friends were retrieved from warp and stored and persisted in state. when a conversation was viewed, all the messages were rendered at once. When someone had multiple conversations with lots of messages, switching between conversations took a long time. Retrieving all this from warp was also slow. By the time this became a problem, lots of other features had been added to the app and it was hard to refactor things while keeping from breaking the rich set of features which had since been added. To cope with this, parts of the codebase depart from the original design. For example, the `chat` layout defines its own `use_shared_state`s and when needed, initializes them with data pulled from `state`. 
- Initially `ui` and `kit` had a similar layout. `kit` was divided into `elements`, `components`, and `layouts` while `ui` was divided into `components` and `layouts`. In `ui/components`,  there was a folder for each view; the root of each view was in `ui/layouts`. As the project grew, views became more complicated and logic started getting pulled into separate modules. The most complicated views were consolidated by moving everything for that view from `ui/src/components` to `ui/src/layouts`. Now parts of the codebase are organized differently. Each developer may have their own preference. Maybe it will be standardized again in the future. I recommend using the style of `ui/src/layouts/chat` for future consolidation. 