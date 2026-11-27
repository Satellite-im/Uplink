module ghostmessaging/twittersidecar

go 1.26.0

require (
	github.com/google/uuid v1.6.0
	github.com/rs/zerolog v1.35.1
	go.mau.fi/mautrix-twitter v0.2609.0
	go.mau.fi/util v0.10.1
)

require (
	github.com/PuerkitoBio/goquery v1.13.0 // indirect
	github.com/andybalholm/brotli v1.2.2 // indirect
	github.com/andybalholm/cascadia v1.3.4 // indirect
	github.com/apache/thrift v0.24.0 // indirect
	github.com/bwesterb/go-ristretto v1.2.4 // indirect
	github.com/coder/websocket v1.8.15 // indirect
	github.com/fxamacker/cbor/v2 v2.9.4 // indirect
	github.com/google/go-querystring v1.2.0 // indirect
	github.com/icholy/digest v1.2.0 // indirect
	github.com/imroc/req/v3 v3.56.0 // indirect
	github.com/klauspost/compress v1.19.2 // indirect
	github.com/mattn/go-colorable v0.1.14 // indirect
	github.com/mattn/go-isatty v0.0.20 // indirect
	github.com/openziti/secretstream v0.1.53 // indirect
	github.com/quic-go/qpack v0.6.0 // indirect
	github.com/quic-go/quic-go v0.61.0 // indirect
	github.com/refraction-networking/utls v1.8.2 // indirect
	github.com/x448/float16 v0.8.4 // indirect
	golang.org/x/crypto v0.57.0 // indirect
	golang.org/x/net v0.59.0 // indirect
	golang.org/x/sys v0.48.0 // indirect
	golang.org/x/text v0.42.0 // indirect
)

// As mautrix-twitter's own go.mod: its HTTP client is Beeper's fork of req. A dependency's replace is not carried
// over, so it is repeated here.
replace github.com/imroc/req/v3 => github.com/beeper/req/v3 v3.0.0-20260808092153-100cef0a2fbd
