# syntax=docker/dockerfile:1.7
# nginx-unprivileged listens on 8080 and runs as UID 101 (no root, no NET_BIND_SERVICE needed)
FROM nginxinc/nginx-unprivileged:1.31.6-alpine3.24@sha256:884e0b7f42f303641b0f4e78755aea647521dca0b89ca3be7992ad78b5c07434
LABEL org.opencontainers.image.title="shoplite-web" \
      org.opencontainers.image.source="https://github.com/timurdll/devops-labs" \
      org.opencontainers.image.licenses="MIT"
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY public/ /usr/share/nginx/html/
USER 101:101
EXPOSE 8080
HEALTHCHECK NONE
