
# Build stage
FROM golang:1.25.7-alpine AS build-stage

WORKDIR /app

COPY go.mod go.sum ./

RUN go mod download

COPY *.go ./

RUN CGO_ENABLED=0 GOOS=linux go build \
    -trimpath \
    -ldflags="-s -w" \
    -o /evaluation-service .

# Runtime stage
FROM gcr.io/distroless/static-debian13:nonroot AS build-release-stage

WORKDIR /

COPY --from=build-stage /evaluation-service /evaluation-service

USER nonroot:nonroot

ENTRYPOINT ["/evaluation-service"]
