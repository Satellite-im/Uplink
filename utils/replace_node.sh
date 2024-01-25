#!/bin/bash

# Read the values from ./warp/peerID
local_peer_id=$(grep -o 'Local PeerID: [^[:space:]]*' ./warp/peerID.txt | awk '{print $NF}')

# Update the values in ./common/src/warp_runner/mod.rs and store in a temporary file
sed -e "s/12D3KooWJSes8386p2T1sMeZ2DzsNJThKkZWbj4US6uPMpEgBTHu/$local_peer_id/g" \
    -e "s#/ip4/104.236.194.35/tcp/34053#/ip4/127.0.0.1/tcp/4444#" \
    ./common/src/warp_runner/mod.rs > temp_file

# Replace the original mod.rs with the modified content
mv temp_file ./common/src/warp_runner/mod.rs
