#!/bin/bash

# Read the values from ./warp/peerID
local_peer_id=$(grep -o 'Local PeerID: [^[:space:]]*' ./warp/peerID.txt | awk '{print $NF}')

# Update the values in ./common/src/warp_runner/mod.rs and store in a temporary file
sed -e "s#cargo build --release -F production_mode#SHUTTLE_ADDR_POINT=/ip4/127.0.0.1/tcp/4444/p2p/ cargo build --release -F production_mode#"
    -e "s/ cargo build --release -F production_mode/$local_peer_id cargo build --release -F production_mode/g" \
    ./Makefile > temp_file

# Replace the original mod.rs with the modified content
mv temp_file ./Makefile
