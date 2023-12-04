<h1 align="center">
  <img src="ui/extra/images/logo.png" width=200 height=200/><br>
  Uplink
</h1>

<h4 align="center">Privacy First, Modular, P2P messaging client built atop Warp.</h4>

<br/>

Uplink is written in pure Rust with a UI in [Dioxus](https://github.com/DioxusLabs) (which is also written in Rust). It was developed as a new foundation for implementing Warp features in a universal application.

The goal should be to build a hyper-customizable application that can run anywhere and support extensions.

![Uplink UI](https://i.imgur.com/X4AGeLz.png)

---
## Pre-Compiled Development

For rapid inspection of our deployed binaries you can open the settings once signed into Uplink, then navigate to "about" and click the version number 10 times which will enable a "developer" section in the settings. From here you can enabled experimental features as well as helpful dev tools.


## Quickstart

To get running fast, ensure you have [Rust](https://www.rust-lang.org/tools/install) installed.

**Standard Run:**
```
cargo run --bin uplink
```

**Rapid Release Testing:**
This version will run close to release but without recompiling crates every time.
```
cargo run --bin uplink --profile=rapid
```

---


## Dependency List

**macOS M1+**
| Dep  | Install Command                                                  |
|------|------------------------------------------------------------------|
| Build Tools| xcode-select --install |
| Homebrew | /bin/bash -c "\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" |
| Rust | curl --proto  '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh |
| cmake | brew install cmake |
| ffmpeg | brew install ffmpeg |
| audio opus | brew install opus |

For this to work, we need to install `ffmpeg` -> `brew install ffmpeg` for macOS
And for Windows, I followed the steps on this site here

**Windows 10+**
| Dep  | Install Command                                                  |
|------|------------------------------------------------------------------|
| Rust | [Installation Guide](https://www.rust-lang.org/tools/install) |
| ffmpeg | [Installation Guide](https://www.geeksforgeeks.org/how-to-install-ffmpeg-on-windows/) |


**Ubuntu WSL (Maybe also Ubuntu + Debian)**
| Dep  | Install Command                                                  |
|------|------------------------------------------------------------------|
| Rust | `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \| sh` |
| Build Essentials | `sudo apt install build-essential` |
| pkg-config | `sudo apt-get install pkg-config` |
| alsa-sys | `sudo apt install librust-alsa-sys-dev` |
| libgtk-dev | `sudo apt-get install libgtk-3-dev` |
| libsoup-dev | `sudo apt install libsoup-3.0-dev` |
| Tauri Deps | `sudo apt install libwebkit2gtk-4.1-dev build-essential curl wget libssl-dev libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev` |
| ffmpeg| `sudo apt-get install ffmpeg` |
| libopus-dev| `sudo apt-get install libopus-dev` |
| libxdo-dev| `sudo apt install libxdo-dev` |

## How to add the extension settings in Uplink:

- Open Uplink and navigate to Settings > Extensions > Settings > Open Extensions.
- In another Finder window, open Uplink.
- Inside Uplink, go to Target > Debug, where you'll find the Emoji selector.
- Drag the Emoji selector to the Extensions window that is still open.
- Close all open windows.
- Finally, run cargo run trace2.

https://github.com/Satellite-im/Uplink/assets/29093946/6f2d5129-4a07-4704-8cc2-0a011056f1e2


## Contributing

All contributions are welcome! Please keep in mind we're still a relatively small team, and any work done to ensure contributions don't cause bugs or issues in the application is much appreciated.

Guidelines for contributing are located in the [`contributing_process.md`](docs/contributing_process.md).

# Contributors

![GitHub Contributors Image](https://contrib.rocks/image?repo=Satellite-im/Uplink)

