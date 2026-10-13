FROM golang:1.27.2 AS build
WORKDIR /src
COPY go.mod go.sum ./
ARG GOPROXY=https://proxy.golang.org,direct
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -o /kelivo-sync .
RUN mkdir -m 0700 /sync-data

FROM scratch
COPY --from=build /kelivo-sync /kelivo-sync
COPY --from=build --chown=65532:65532 /sync-data /data
USER 65532:65532
WORKDIR /data
ENTRYPOINT ["/kelivo-sync"]
CMD ["-addr", "0.0.0.0:8787", "-db", "/data/sync.db"]
