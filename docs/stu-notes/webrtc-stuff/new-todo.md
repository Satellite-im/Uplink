
open a data channel between peers who are in a call
send a time sync message (3 packets total)
use round trip time to determine 
    - the number of audio packets that should be buffered
    - when audio degradation is likely to occur (round trip time increases)
    - if a burst of audio packets have been received, how many should be discarded. 


# blink signaling test cases
- two incoming calls at once
- group calls - can everyone be heard? 
- group calls where multiple ppl join then 1 leaves, does the pending call get cleared? it shouldn't. 


# todo
- add reject option to blink-repl


# requirements
dial 1 or more peers
peers can reject the call, accept the call, or take no action
if everyone leaves the call, it will not be shown as a pending call. 
for a 2 way call (not a group call), if one person leaves, the call automatically ends.
for a group call, if everyone else leaves, the call can continue. 
people can leave and re-join the call as needed
if someone turns on uplink, they will be invited to the call 
    -> someone sends the offer signal periodically until everyone receives it
    -> maybe the same thing for the leave signal? 
    -> use raygun for signaling? 
    -> what if two tasks simultaneously are trying to send the join and leave signals? problem. 
if someone leaves, turns off the app, and turns it on again, they can join the call
if someone rejects the call, they won't be invited to join the call in the future. (need a new signal for reject then.)

show a missed call?

if someone joins a call, need to see who is muted/unmuted and deafened/undeafened
    - ask every peer for this information?
    - if a peer sends their information via a datachannel and also updates their info and broadcasts it, need a way to reconcile. 
    - have all peers broadcast their state every x seconds? 
    - use raygun for this?

# stream management
- when a call is offered, spawn a task which subscribes to the stream and uses a mpsc channel to forward events
- control the streams  using a broadcast channel? or have them drop automatically --> this one? 

# reducing locks
- have a task that will send stuff over ipfs. use a channel to tell it what to send. 
- need something to manage webrtc_controller - in response to webrtc events and IPFS events...

for the call listener - track state for all calls. 
add command to set the active call (returns the call config)
for the active call, emit events
have command to retrieve call config 