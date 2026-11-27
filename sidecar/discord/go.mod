module ghostmessaging/discordsidecar

go 1.26.0

replace github.com/bwmarrin/discordgo => github.com/beeper/discordgo v0.0.0-20260808090638-8051e14a4471

replace github.com/imroc/req/v3 => github.com/beeper/req/v3 v3.0.0-20260808092221-1540c0bf3d1a

require (
	github.com/bwmarrin/discordgo v0.27.0
	github.com/coder/websocket v1.8.14
	github.com/imroc/req/v3 v3.60.0
	github.com/refraction-networking/utls v1.8.2
	github.com/rs/zerolog v1.35.1
	go.mau.fi/util v0.11.1
)

require (
	github.com/andybalholm/brotli v1.2.2 // indirect
	github.com/google/go-querystring v1.2.0 // indirect
	github.com/google/uuid v1.6.0 // indirect
	github.com/icholy/digest v1.2.0 // indirect
	github.com/klauspost/compress v1.19.2 // indirect
	github.com/mattn/go-colorable v0.1.14 // indirect
	github.com/mattn/go-isatty v0.0.20 // indirect
	github.com/quic-go/qpack v0.6.0 // indirect
	github.com/quic-go/quic-go v0.61.0 // indirect
	golang.org/x/crypto v0.58.0 // indirect
	golang.org/x/net v0.62.0 // indirect
	golang.org/x/sys v0.50.0 // indirect
	golang.org/x/text v0.44.0 // indirect
)
