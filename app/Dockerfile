# ---------- Stage 1: build del binario Go ----------
FROM golang:1.25-alpine AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /out/tasky

# ---------- Stage 2: immagine di runtime ----------
FROM alpine:3.24

WORKDIR /app
COPY --from=build /out/tasky ./tasky
COPY assets ./assets

# Requisito dell'esercizio: file con il nome del candidato dentro l'immagine.
# Viene copiato dal repository al build; verifica in esecuzione con:
#   kubectl exec -n tasky deploy/tasky -- cat /app/wizexercise.txt
COPY wizexercise.txt /app/wizexercise.txt

ENV GIN_MODE=release
EXPOSE 8080

# Il container non gira come root
USER 65532:65532
ENTRYPOINT ["/app/tasky"]
