<h1 align="center">
  <a href="https://satellite.im" target="_blank">
  <img src="ui/extra/images/logo.png" width=200 height=200/><br>
  Uplink
  </a>
</h1>

<h4 align="center">Privacy First, Modular, P2P messaging client built atop Warp.</h4>

<br/>

Uplink is written in pure Rust with a UI in [Dioxus](https://github.com/DioxusLabs) (which is also written in Rust). It was developed to be a new foundation for the basic implementation of Warp features in a universal application.

The goal should be to build a hyper-customizable application that can run anywhere and support extensions.

![Uplink UI](https://i.imgur.com/X4AGeLz.png)

Implementation of a UI atop Warp using a standardized State model and UIKit to reinforce reusable component usage.

---

## Quickstart

To get running fast ensure you have [Rust](https://www.rust-lang.org/tools/install) installed.


**Standard Run:**
```
cargo run --bin ui
```

**Rapid Release Testing:**
This version will run closely to release but without recompiling crates every time.
```
cargo run --bin ui --profile=rapid
```

---


## Dependancy List

**MacOS M1+**
| Dep  | Install Command                                                  |
|------|------------------------------------------------------------------|
| Build Tools| xcode-select --install |
| Rust | curl --proto  '=https' --tlsv1.2 -sSf https://sh.rustup.rs \| sh |

**Windows 10+**
| Dep  | Install Command                                                  |
|------|------------------------------------------------------------------|
| Chocolatey | [Installation Guide](https://chocolatey.org/install) |
| Rust | choco install rust |

## Contributing

All contributions are welcome! Please keep in mind we're still a relatively small team and any work done to make sure contributions don't cause bugs or issues in the application is much appreciated.

Guidelines for contributing are located in the [`CONTRIBUTING.md`](CONTRIBUTING.md).

---

# Things to fix/implement

We should try to finish this checklist before switching over to using this UI for the primary Uplink UI.

- [x] Skeletal loaders for all relevant components inside the UIKit
  - [x] User Image
  - [x] Message
  - [ ] Button
  - [ ] Label
  - [ ] Select
  - [x] File
  - [x] Folder
  - [x] User
  - [x] Chat
  - [x] Friend
- [x] Toast Notifications
  - [x] Ability to push a new toast notification.
  - [x] Toast notification automatically dismisses after `n` seconds.
  - [ ] Hovering over the toast notification should reset the dismiss timer.
  - [x] Clicking the `x` on the toast notification should dismiss it immediately.
- [ ] Calling Modal
  - [ ] Should be wired to state to appear when ui.incoming_call is set to some call.
  - [ ] We should outline a struct to neatly contain info we need pertaining to an incoming call.
- [ ] Files
  - [ ] Files should be able to be dragged and dropped into a folder in order to move the file into the folder.
  - [ ] We should be able to drag and drop to re-organize the files page
  - [ ] We should be able to rename folders
  - [ ] We should be able to drag and drop folders into folders.
  - [ ] We should be able to navigate using the breadcrumbs.
  - [ ] we should be able to delete files and folders. Deleting a folder should delete all the items inside a folder.
  - [ ] Deleting things should move them to a "trash" folder which will have a different icon. 
  - [ ] Emptying trash will delete everything in the trash.
- [x] Language & Translation
  - [x] Replace all references to the plain text within the app with references to the translated items
  - [x] Ensure that there is no hard-coded text within the UIKit that we can't override with props. 
- [ ] Messaging
  - [ ] Add mock data to generate random replies to messages
  - [ ] Add mock data to generate random reactions to messages 
  - [ ] Add mock data to include random attachments on messages
  - [ ] Add the ability to "edit" messages.
  - [ ] Implement UI for the afformentioned items.
- [ ] Settings should be wired to a config file and automatically update.
- [ ] CSS needs to be split up neater within components and layouts in uplink_skeleton.
- [x] Unlock page needs porting.
- [ ] Account creation page needs porting.
- [x] Add generic loader component.
- [ ] Add a config option to enable developer logging
  - [ ] Developer logging should write developer logs to uplink-debug.log
  - [ ] Include a way to view the contents of the log-in developer settings.
    - [ ] Include a copy button to copy the log to the clipboard.
  - [ ] Debug logging should also log neatly to the rust console.
- [ ] Profile Page in settings
- [ ] Profile page popup option for user_image 
