FROM golang:1.23-alpine AS builder

WORKDIR /app
COPY go.mod ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /simulator ./cmd/simulator

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=builder /simulator /simulator

EXPOSE 8000 9000
ENTRYPOINT ["/simulator"]
