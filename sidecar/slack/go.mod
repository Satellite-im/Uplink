module ghostmessaging/slacksidecar

go 1.26.0

require (
	github.com/gorilla/websocket v1.5.0
	github.com/rs/zerolog v1.35.1
	github.com/slack-go/slack v0.24.0
	go.mau.fi/mautrix-slack v0.2611.0
)

require (
	github.com/mattn/go-colorable v0.1.14 // indirect
	github.com/mattn/go-isatty v0.0.20 // indirect
	go.mau.fi/util v0.11.1 // indirect
	golang.org/x/net v0.62.0 // indirect
	golang.org/x/sys v0.50.0 // indirect
)

replace github.com/slack-go/slack => github.com/beeper/slackgo v0.0.0-20261109170826-c51406334f5e
