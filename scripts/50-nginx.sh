#!/usr/bin/env bash
# 50-nginx: reverse proxy vhost + optional Let's Encrypt via certbot.
# Set DOMAIN to enable; skips otherwise. Set CERTBOT_EMAIL for
# unattended certificate issuance.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
: "${DOMAIN:=}"
: "${ODOO_VERSION:=18.0}"
: "${CERTBOT_EMAIL:=}"

[ -z "$DOMAIN" ] && { echo "DOMAIN not set, skipping nginx."; exit 0; }

apt-get install -y -qq nginx certbot python3-certbot-nginx

# /websocket (Odoo >= 16) vs /longpolling/ (Odoo <= 15), same 8072 port.
WS_PATH=/websocket
case "$ODOO_VERSION" in
  8.*|9.*|1[0-5].*) WS_PATH=/longpolling/ ;;
esac

BEDROCK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
sed -e "s/@DOMAIN@/$DOMAIN/g" -e "s|@WS_PATH@|$WS_PATH|" \
  "$BEDROCK_DIR/templates/nginx.conf" > /etc/nginx/sites-available/odoo
ln -sf /etc/nginx/sites-available/odoo /etc/nginx/sites-enabled/odoo
nginx -t && systemctl reload nginx

if [ -n "$CERTBOT_EMAIL" ]; then
  certbot --nginx -d "$DOMAIN" -m "$CERTBOT_EMAIL" --agree-tos -n --redirect
  systemctl reload nginx
else
  echo "nginx vhost installed for $DOMAIN."
  echo "For HTTPS: certbot --nginx -d $DOMAIN  (or set CERTBOT_EMAIL and re-run for unattended issuance)"
fi
