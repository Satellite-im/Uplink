# Read the values from .\warp\peerID.txt
$localPeerID = Select-String -Path .\warp\peerID.txt -Pattern 'Local PeerID: ([^\s]+)' | ForEach-Object { $_.Matches.Groups[1].Value }

# Update the values in .\common\src\warp_runner\mod.rs and store in a temporary file
(Get-Content .\Makefile) -replace 'cargo build --release -F production_mode', 'SHUTTLE_ADDR_POINT=/ip4/127.0.0.1/tcp/4444/p2p/ cargo build --release -F production_mode' -replace ' cargo build --release -F production_mode', "$localPeerID cargo build --release -F production_mode" | Set-Content -Path temp_file

# Replace the original mod.rs with the modified content
Move-Item -Path temp_file -Destination .\Makefile
