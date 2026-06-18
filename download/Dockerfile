# Source the versatiles binary from the official image. It is a static musl
# binary, so it runs as-is when copied into the Alpine stage below — no shared
# libraries to carry over. Used by update-tiles.sh to build the zoom-limited
# local subset of large datasets (e.g. satellite) via `versatiles convert`.
FROM versatiles/versatiles:latest AS versatiles

FROM alpine:3

# aria2 for fast parallel CDN downloads; curl for fetching the .md5 sidecars;
# bash for the update script.
RUN apk add --no-cache aria2 curl bash

# versatiles CLI for `convert` (zoom-limited subset builds). Static binary, so
# no runtime dependencies are needed.
COPY --from=versatiles /app/versatiles /usr/local/bin/versatiles

WORKDIR /app

# Copy the pipeline script
COPY update-tiles.sh ./

# Create non-root user that owns the working directory (matches the UID expected
# on the mounted volumes)
RUN addgroup -g 1001 -S appuser && adduser -S appuser -u 1001 -G appuser \
    && chown appuser:appuser /app

USER appuser

# Run the pipeline (ENTRYPOINT so extra args like --mode=prepare are passed
# straight to the script)
ENTRYPOINT ["/app/update-tiles.sh"]
