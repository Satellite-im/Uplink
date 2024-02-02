<h1 align="center">
  <img src="ui/extra/images/logo.png" width=200 height=200/><br>
  Uplink
</h1>

test

<h4 align="center">Privacy First, Modular, P2P messaging client built atop Warp.</h4>

<br/>

Uplink is written in pure Rust with a UI in [Dioxus](https://github.com/DioxusLabs) (which is also written in Rust). It was developed as a new foundation for implementing Warp features in a universal application.

The goal should be to build a hyper-customizable application that can run anywhere and support extensions.

![Uplink UI](https://i.imgur.com/X4AGeLz.png)

---
## Pre-Compiled Development

For rapid inspection of our deployed binaries, you can open the settings once signed into Uplink, then navigate to `About` and click the version number 10 times, enabling a `Developer` section in the settings. From here, you can enable experimental features and helpful dev tools.


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
| Build Tools| `xcode-select --install` |
| Homebrew | `/bin/bash -c "\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"` |
| Rust | `curl --proto  '=https' --tlsv1.2 -sSf https://sh.rustup.rs` | sh |
| cmake | `brew install cmake` |
| ffmpeg | `brew install ffmpeg` |
| audio opus | `brew install opus` |

You can also run [macos-install_dependencies.sh](https://github.com/Satellite-im/Uplink/blob/sara/add-macos-script/macos-install_dependencies.sh) to install all of the above in bulk.

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

**Fedora 38**
| Dep  | Install Command                                                  |
|------|------------------------------------------------------------------|
| Rust | `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \| sh` |
| Build Essentials | `sudo dnf groupinstall "Development Tools" "Development Libraries"` |
| pkg-config | `sudo dnf install pkg-config` |
| alsa libs & headers | `sudo dnf install alsa-lib-devel` |
| libgtk-dev | `sudo dnf install gtk3-devel` |
| libsoup-dev | `sudo dnf install libsoup3-devel` |
| Tauri Deps | `sudo dnf install webkit2gtk4.1-devel openssl-devel curl wget librsvg2-devel libindicator-devel` |
| ffmpeg| `sudo dnf install ffmpeg` |
| libopus-dev| `sudo dnf install opus-devel` |
| libxdo-dev| `sudo dnf install libxdo-devel` |


## Contributing

All contributions are welcome! Please keep in mind we're still a relatively small team, and any work done to ensure contributions don't cause bugs or issues in the application is much appreciated.

Guidelines for contributing are located in the [`contributing_process.md`](docs/contributing_process.md).

# Contributors

![GitHub Contributors Image](https://contrib.rocks/image?repo=Satellite-im/Uplink)
