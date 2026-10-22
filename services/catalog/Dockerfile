# syntax=docker/dockerfile:1.7
# ---- Stage 1: install production dependencies only (no dev deps, no lifecycle scripts)
FROM node:24-alpine@sha256:44fce696f38ba8c987c4db89954051000bbd05ffd8d8659ba15ed4a8602e937f AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund

# ---- Stage 2: minimal runtime — distroless has no shell, no package manager, runs as UID 65532
FROM gcr.io/distroless/nodejs24-debian13:nonroot@sha256:78f07ef1b5ea71ad7c055df15d0dd8997f2d288f9158623c4d4ae3d765b7d50d
LABEL org.opencontainers.image.title="shoplite-catalog" \
      org.opencontainers.image.source="https://github.com/timurdll/devops-labs" \
      org.opencontainers.image.licenses="MIT"
WORKDIR /app
ENV NODE_ENV=production PORT=8080
COPY --from=deps --chown=65532:65532 /app/node_modules ./node_modules
COPY --chown=65532:65532 package.json ./
COPY --chown=65532:65532 src ./src
USER 65532:65532
EXPOSE 8080
CMD ["src/server.js"]
