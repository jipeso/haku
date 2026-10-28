# syntax=docker/dockerfile:1

FROM golang:1.27.3 AS base
WORKDIR /src

FROM base AS dev
CMD ["go", "tool", "air"]

FROM base AS build
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/haku ./cmd/haku \
 && mkdir /out/data

FROM gcr.io/distroless/static-debian13:nonroot AS prod
COPY --from=build /out/haku /haku
COPY --from=build --chown=65532:65532 /out/data /data
ENTRYPOINT ["/haku"]
CMD ["run"]
