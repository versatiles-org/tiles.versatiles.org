FROM node:26-alpine

# Install aria2 for fast parallel CDN downloads and update npm
RUN apk add --no-cache aria2 && npm install -g npm@latest

WORKDIR /app

# Copy package files first for better layer caching
COPY package*.json ./

# Install dependencies
RUN npm ci --omit=dev

# Copy source code
COPY . .

# Create non-root user that owns the working directory
RUN addgroup -g 1001 -S appuser && adduser -S appuser -u 1001 \
    && chown appuser:appuser /app

USER appuser

# Run the pipeline (ENTRYPOINT so extra args like --mode=prepare are passed
# to the script, not interpreted by the node docker-entrypoint.sh wrapper)
ENTRYPOINT ["npx", "tsx", "src/run_once.ts"]
