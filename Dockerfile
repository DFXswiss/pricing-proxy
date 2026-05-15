FROM openresty/openresty:1.27.1.2-alpine

# nginx top-level config (env passthrough, shared dicts, resolver with ipv6=off)
COPY nginx.conf   /usr/local/openresty/nginx/conf/nginx.conf
# server block: public /<upstream>/ locations + internal /_internal/<upstream>/ proxy_pass targets
COPY pricing.conf /etc/nginx/conf.d/default.conf
# request handler: cache → coalescing lock → upstream → JSON validate → cache store
COPY proxy.lua    /etc/nginx/lua/proxy.lua
# background quota monitor: periodic /api/v3/key probe → Telegram alerting
COPY monitor.lua  /etc/nginx/lua/monitor.lua

EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=5s --retries=3 \
    CMD wget -qO- --timeout=3 http://127.0.0.1:8080/health || exit 1
