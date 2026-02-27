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

# Create non-root user and writable directories for vite build
RUN addgroup -g 1001 -S appuser && adduser -S appuser -u 1001 \
    && mkdir -p /app/data /app/build /app/.svelte-kit \
    && chown -R appuser:appuser /app/data /app/build /app/.svelte-kit

USER appuser

# Expose port 8081 for the webhook server
EXPOSE 8081

# Run the server
CMD ["npx", "tsx", "src/server.ts"]
