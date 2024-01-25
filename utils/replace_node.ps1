# Contents of replace_node.ps1

# Read the values from ./warp/peerID
$localPeerId = Select-String -Path .\warp\peerID.txt -Pattern 'Local PeerID: ([^\s]*)' | ForEach-Object { $_.Matches.Groups[1].Value }

# Update the values in ./common/src/warp_runner/mod.rs and store in a temporary file
(Get-Content .\common\src\warp_runner\mod.rs) -replace '12D3KooWJSes8386p2T1sMeZ2DzsNJThKkZWbj4US6uPMpEgBTHu', $localPeerId `
                                                      -replace '/ip4/104.236.194.35/tcp/34053', '/ip4/127.0.0.1/tcp/4444' |
    Set-Content -Path .\common\src\warp_runner\mod.rs

