FROM alpine:3

# aria2 for fast parallel CDN downloads; curl for fetching the .md5 sidecars;
# bash for the update script.
RUN apk add --no-cache aria2 curl bash

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
