-`enum MessageEventKind`
    -  processed by the implementors
    - extensions/warp-rg-ipfs has a `direct_message_event` where a conversations messges `messages` are modified and an event is broadcast. 
    - warp-rg-ipfs/src/store has a `enum MessagingEvents` which matches `MessageEventKind`. 
    - `direct_message_event` maps from a `MessagingEvents` to a `MessageEventkind`

- `trait RayGun`
    - add a function here for the typing indicator
    - future functions needed: call, video call
    - video call will need to be able to add sources during the call. other source is the screen or a window. 

- ideas
    - add an Indicator enum. let it indicate typing/not, and in the future, perhaps active/idle. 