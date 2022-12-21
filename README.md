# Uplink UI

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


---

## Todo

- [x] File Component
- [x] Vertical Nav
- [ ] User with Controls
- [x] Chatbar
- [x] Message Reply
- [x] Message Reply above Chatbar
- [ ] Reaction Menu
- [x] Typing Indicator
- [x] Typing Indicator Message
- [x] Mini User (Favorites)
- [ ] All Loading States
- [x] Switch Disabled
- [x] Folder Disabled
- [x] Input Disabled
- [ ] Generic Error
- [x] File Embed
