
# Command Cheat Sheet (Unix)

# Logging
### Show Help Commands:
```cargo run --release -- --help```


### Write debug level logs to file
#### delete log and start new (using default uplink folder)
```rm ~/.uplink/.user/debug.log && cargo run --release -- debug-all```

#### append
```cargo run --release -- debug-all```

### Write debug level logs to console
```cargo run --release -- debug```

### Write trace log levels and INCLUDE warp logging
```cargo run --release -- trace-warp```

____
## Run Multiple Uplinks locally
```cargo run --release -- --path ~/path/to/profile/you/want```

___

## Copy Extensions and Run App (from within the Uplink folder)
#### dylib is a macOS specific extension, it will have a different extension on Windows and Linux
```cargo build --release && cp ./target/release/libemoji_selector.dylib ~/.uplink/extensions && cargo run --release```

___
## Wipe out your state.json file
#### Default uplink profile
```rm ~/.uplink/.user/state.json```
