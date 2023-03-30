cargo build --release --package uplink
Compress-Archive -LiteralPath ../ui/extra -DestinationPath ../target/release/assets.zip
cargo wix --package uplink --nocapture