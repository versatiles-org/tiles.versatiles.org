# Source the versatiles binary from the official image. It is a static musl
# binary, so it runs as-is when copied into the Alpine stage below — no shared
# libraries to carry over. Used by update-tiles.sh to build derived datasets
# (zoom-limited subsets, merges, …) via `versatiles convert` + VPL.
FROM versatiles/versatiles:latest AS versatiles

FROM alpine:3

# aria2 for fast parallel CDN downloads; curl for fetching the .md5 sidecars;
# jq for reading the source manifest (sources.json); bash for the update script.
RUN apk add --no-cache aria2 curl jq bash

# versatiles CLI for `convert` (VPL builds: subsets, merges, …). Static binary,
# so no runtime dependencies are needed.
COPY --from=versatiles /app/versatiles /usr/local/bin/versatiles

WORKDIR /app

# Copy the pipeline script and the source manifest it is driven by.
COPY update-tiles.sh sources.json ./

# Create non-root user that owns the working directory (matches the UID expected
# on the mounted volumes)
RUN addgroup -g 1001 -S appuser && adduser -S appuser -u 1001 -G appuser \
    && chown appuser:appuser /app

USER appuser

# Run the pipeline (ENTRYPOINT so extra args like --mode=prepare are passed
# straight to the script)
ENTRYPOINT ["/app/update-tiles.sh"]
