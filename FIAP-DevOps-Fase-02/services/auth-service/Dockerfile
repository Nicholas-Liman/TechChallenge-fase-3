FROM golang:1.25.7-alpine AS builder

WORKDIR /app

# Configura o proxy oficial do Go
ENV GOPROXY=https://proxy.golang.org,direct

# Instala certificados e Git para download das dependências
RUN apk add --no-cache ca-certificates git

# Copia os arquivos do projeto
COPY . .

# Organiza e baixa as dependências
RUN go mod tidy
RUN go mod download

# Compila o binário de forma estática
RUN CGO_ENABLED=0 GOOS=linux go build -o auth-service .

FROM gcr.io/distroless/static-debian11 AS build-release-stage

WORKDIR /

# Copia o binário compilado
COPY --from=builder /app/auth-service /auth-service

EXPOSE 8001

USER nonroot:nonroot

ENTRYPOINT ["/auth-service"]