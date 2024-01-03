
Sender
starts with Blink::offer_call
    BlinkImpl::init_call sets up the audio source track and sets up the signaling streams: call, peer, webrtc
    sends InitiationSignal::Offer { call_info }

Recipient
receives InitiationSignal::Offer { call_info }
emits event BlinkEventKind::IncomingCall
user calls Blink::answer_call
    BlinkImpl::init_call is called
    emit CallSignal::Join { cal_id }

All other call participants
receive CallSignal::Join and call webrtc_controller::dial for that peer
    the peers automatically call webrtc_controller::dial
        generates local SDP, begins gathering ice candidates, and returns local SDP
    emits an event EmittedEvents::CallInitiated { sdp }
the sdp from this event is taken and sent to Recipient via PeerSignal::Dial { sdp }

Recipient 
receives PeerSignal::Dial { sdp }
calls webrtc_controller::accept_call, which emits the EmittedEvents::Sdp event
    this triggers the webrtc connection process. ICE candidates start getting created and sent to the other side. 
sends back PeerSignal::Sdp { sdp }

other participants
receive their own PeerSignal::Sdp { sdp } and call webrtc_controller::recv_sdp