

# signaling (pubsub)
- each peer subscribes to offer_call/DID
    - calls are offered via this. every participant receives their own message for this call 
    - contains the Uuid of the call and the participants
    - if group conversations work differently, may want to use that later. but as of now group conversations aren't implemented 
- after accepting, 
    - subscribe to telecon/Uuid and let peers broadcast `Hello`
    - subscribe to telecon/uuid/DID and receive signals 
- for each pair of peers, let the peer with the lower DID initiate the webRTC connection. meaning if a peer receives a SDP from a peer with a lower DID, they should reply
- only broadcast `Hello`
    - the first X seconds after joining a call
    - the first X seconds after someone with a higher DID joins the call (determined by receiving a broadcast from them)

# difficulty
- simple_webrtc requires channels (necessarily). blink needs a task to process these channels
- cpal::Stream is !Sync. need a separate thread to manage streams (SourceTracks)


# why simple_webrtc needs channels
- `peer_connection.on_ice_candidate`
- `peer_connection.on_ice_connection_state_change`
- `peer_connection.on_track`
- any function starting with `fn on_` in `RTCPeerConnection`

# todo
- store within each `Peer` the list of media sources which the peer is subscribed to. 
- store within `Controller` the list of media sources local is subscribed to, for each peer
- in simple_webrtc::Controller
    - in the init function, specify the codecs used. 
    - pub/sub1
        - add function for peers to subscribe to media sources
        - add function to subscribe self to peers' media sources
            - when on_track triggers, you can verify that the track was subscribed to. 
    - pub/sub2
        - the connect() function specifies the media sources to be used. 
        - if a peer isn't providing a media source specified in connect(), don't add a track for it.
        - add_media_source now only accepts a mime type. maybe call add_media_source automatically (would need to return a list of source tracks)

# Design
- needs an event loop to poll WebRTC events and update self
- needs to receive WebRTC signals externally, which updates self. (another event loop?)
- also needs to be accessible to library users. 
- should there be a Mutex? 

# Design2
- build on top of simple-webrtc
    - SourceTrack and SinkTrack move data in and out of simple-webrtc
    - modify simple-webrtc to be smarter about connecting rtc streams to peers 

struct BlinkWrtc {
    - track peers for call
    - track self's published streams
    - track peers' published streams 
    - track self's subscribed streams
    - track peers' subscribed streams
    - drive simple-webrtc 
        - use an Ipfs<T> for signaling 
        - receive signals over Ipfs
        - update self in response to asynchronous events while allowing a library to use Blink
    - things that require an event loop
        - handle WebRTC events emitted by simple-webrtc
        - respond to WebRTC signals received via Ipfs
    
    - BlinkWrtc should implement Blink via an Arc<Mutex<BlinkImpl>>. This BlinkImpl would also be used in the event loop
    - contain a JoinHandle for the event loop

    - can RayGun and Blink share the same IPFS instance? -> yes, call multipass.handle() to get an Option<Ipfs<T>>
}

# connection flow
- local creates a TrackLocalStaticRTP via add_media_source
- the stream is offered
- a peer subscribes to the stream (must happen when or before they connect)
- a peer initiates a connection (perhaps with a list of streams they want)


// todo: possibly name this better
struct Controller {

    local {
        // actively sampling for each one
        published_streams:  HashMap< stream_id,{
            media_type,
            codec,
            SourceTrack,
            subscribers: HashMap< peer_id, TrackRemote>,
        }>,

        subscribed_streams: HashMap< stream_id, {
            peer_id,
            media_type,
            codec,
            track: SinkTrack
        }>
    },
    

    peers: HashMap< peer_id, {
        call_state {joined, not_joined, declined},
        // todo: add state for setting up the streams? 
        published_streams {stream_id, stream_type, codec},
        subscribed_streams,
        // add tracks to the RTCPeerConnection. emits the TrackLocal in an event -> have to write to the track
        // receive tracks from the RTCPeerConnection. emits the TrackRemote in an event -> have to read from the track
        connection: RtcPeerConnection,
    }>,
}

# media stream management
- to mute self, stop sending audio samples to RTP
- to mute others, drop their audio stream (special feature)
- call muting self "pause"

pub trait SinkTrack {
    fn init();
    fn play();
    fn change_output_device();
}

pub trait SourceTrack {
    fn init();
    fn play();
    fn pause();
    fn change_input_device();
}