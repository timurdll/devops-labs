# syntax=docker/dockerfile:1.7
# nginx-unprivileged listens on 8080 and runs as UID 101 (no root, no NET_BIND_SERVICE needed)
FROM nginxinc/nginx-unprivileged:1.30.6-alpine3.24@sha256:782bb89768cc87b7f95c18b95baa1af250e5d451f26794f59363540161147c01
LABEL org.opencontainers.image.title="shoplite-web" \
      org.opencontainers.image.source="https://github.com/timurdll/devops-labs" \
      org.opencontainers.image.licenses="MIT"
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY public/ /usr/share/nginx/html/
USER 101:101
EXPOSE 8080
HEALTHCHECK NONE
