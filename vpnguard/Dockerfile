FROM golang:1.22-alpine AS builder

WORKDIR /build
COPY . .
RUN go mod download && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /out/vpnguard .

FROM alpine:3.19

RUN apk add --no-cache ca-certificates tzdata
WORKDIR /app
COPY --from=builder /out/vpnguard /app/vpnguard
ENTRYPOINT ["/app/vpnguard"]
