<h1 align="center">
  <img src="ui/extra/images/logo.png" width=200 height=200/><br>
  Uplink
</h1>

<h4 align="center">Privacy First, Modular, P2P messaging client built atop Warp.</h4>

<br/>

Uplink is written in pure Rust with a UI in [Dioxus](https://github.com/DioxusLabs) (which is also written in Rust). It was developed to be a new foundation for the basic implementation of Warp features in a universal application.

The goal should be to build a hyper-customizable application that can run anywhere and support extensions.

![Uplink UI](https://i.imgur.com/X4AGeLz.png)

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
| Homebrew | /bin/bash -c "\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" |
| Rust | curl --proto  '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh |
| cmake | brew install cmake |
| Protoc | brew install protobuf |

**Windows 10+**
| Dep  | Install Command                                                  |
|------|------------------------------------------------------------------|
| Chocolatey | [Installation Guide](https://chocolatey.org/install) |
| Rust | choco install rust |

**Ubuntu WSL (Maybe also Ubuntu + Debian)**
| Dep  | Install Command                                                  |
|------|------------------------------------------------------------------|
| Rust | `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \| sh` |
| Build Essentials | `sudo apt install build-essential` |
| pkg-config | `sudo apt-get install pkg-config` |
| alsa-sys | `sudo apt install librust-alsa-sys-dev` |
| libgtk-dev | `sudo apt-get install libgtk-3-dev` |
| libsoup-dev | `sudo apt install libsoup2.4-dev` |
| protobuf| `sudo apt-get install protobuf-compiler` |
| Tauri Deps | `sudo apt install libwebkit2gtk-4.0-dev build-essential curl wget libssl-dev libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev` |

## Contributing

All contributions are welcome! Please keep in mind we're still a relatively small team and any work done to make sure contributions don't cause bugs or issues in the application is much appreciated.

Guidelines for contributing are located in the [`CONTRIBUTING.md`](CONTRIBUTING.md).
