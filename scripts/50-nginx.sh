#!/usr/bin/env bash
# 50-nginx: reverse proxy vhost + optional Let's Encrypt via certbot.
# Set DOMAIN to enable; skips otherwise. Set CERTBOT_EMAIL for
# unattended certificate issuance.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
: "${DOMAIN:=}"
: "${ODOO_VERSION:=18.0}"
: "${CERTBOT_EMAIL:=}"

# shellcheck source=lib-instance.sh
source "$(dirname "$0")/lib-instance.sh"

[ -z "$DOMAIN" ] && { echo "DOMAIN not set, skipping nginx."; exit 0; }

apt-get install -y -qq nginx certbot python3-certbot-nginx

# /websocket (Odoo >= 16) vs /longpolling/ (Odoo <= 15), same longpolling port.
WS_PATH=/websocket
case "$ODOO_VERSION" in
  8.*|9.*|1[0-5].*) WS_PATH=/longpolling/ ;;
esac

SITE=/etc/nginx/sites-available/odoo

# Refuse to hijack a server_name another enabled vhost already serves.
# nginx picks whichever duplicate block loads first, so a fresh (empty)
# instance can silently take over a live prod domain. Deliberate takeover:
# FORCE_NGINX=1.
if [ "${FORCE_NGINX:-0}" != 1 ]; then
  _clash=$(grep -rlE "^[[:space:]]*server_name[[:space:]].*(^|[[:space:]])${DOMAIN//./\\.}([[:space:]]|;|$)" \
    /etc/nginx/sites-enabled/ 2>/dev/null | grep -v "/$(basename "$SITE")$" || true)
  if [ -n "$_clash" ]; then
    echo "ERROR: server_name $DOMAIN is already declared by:" >&2
    echo "$_clash" >&2
    echo "Put this instance on its own domain/port (ODOO_PORT=, DOMAIN=)," >&2
    echo "or set FORCE_NGINX=1 if replacing that instance on purpose." >&2
    exit 1
  fi
fi

render_nginx "$DOMAIN" "$WS_PATH" "${ODOO_PORT:-8069}" "${LONGPOLLING_PORT:-8072}" \
  "$SITE"
ln -sf /etc/nginx/sites-available/odoo /etc/nginx/sites-enabled/odoo

# nginx config check; then reload a running master, or start one
# (containers have no systemd/service, so plain `nginx` daemonizes).
nginx -t
if [ -f /run/nginx.pid ] && kill -0 "$(cat /run/nginx.pid)" 2>/dev/null; then
  nginx -s reload
else
  nginx
fi

if [ -n "$CERTBOT_EMAIL" ]; then
  certbot --nginx -d "$DOMAIN" -m "$CERTBOT_EMAIL" --agree-tos -n --redirect
  nginx -s reload 2>/dev/null || systemctl reload nginx 2>/dev/null || true
else
  echo "nginx vhost installed for $DOMAIN."
  echo "For HTTPS: certbot --nginx -d $DOMAIN  (or set CERTBOT_EMAIL and re-run for unattended issuance)"
fi
