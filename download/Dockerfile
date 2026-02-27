FROM node:22-alpine

# Install openssh-client for remote hash generation
RUN apk add --no-cache openssh-client

WORKDIR /app

# Copy package files first for better layer caching
COPY package*.json ./

# Install dependencies
RUN npm ci --omit=dev

# Copy source code
COPY . .

# Create non-root user with write access to directories needed by vite build
RUN addgroup -g 1001 -S appuser && adduser -S appuser -u 1001 \
    && chown appuser:appuser /app \
    && mkdir -p /app/data /app/build /app/.svelte-kit \
    && chown appuser:appuser /app/data /app/build /app/.svelte-kit

USER appuser

# Run the pipeline
CMD ["npx", "tsx", "src/run_once.ts"]
