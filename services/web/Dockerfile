# syntax=docker/dockerfile:1.7
# nginx-unprivileged listens on 8080 and runs as UID 101 (no root, no NET_BIND_SERVICE needed)
FROM nginxinc/nginx-unprivileged:1.31.5-alpine3.24@sha256:19c132c9ab02d3b783f478743dafc7a7f42e27aa7d2bdcbec1bb1128ca8f2a07
LABEL org.opencontainers.image.title="shoplite-web" \
      org.opencontainers.image.source="https://github.com/timurdll/devops-labs" \
      org.opencontainers.image.licenses="MIT"
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY public/ /usr/share/nginx/html/
USER 101:101
EXPOSE 8080
HEALTHCHECK NONE
