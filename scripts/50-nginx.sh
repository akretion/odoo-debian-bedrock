#!/usr/bin/env bash
# 50-nginx: reverse proxy vhost. Set DOMAIN to enable; skips otherwise.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
: "${DOMAIN:=}"

[ -z "$DOMAIN" ] && { echo "DOMAIN not set, skipping nginx."; exit 0; }

apt-get install -y -qq nginx
BEDROCK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
sed -e "s/@DOMAIN@/$DOMAIN/g" "$BEDROCK_DIR/templates/nginx.conf" \
  > /etc/nginx/sites-available/odoo
ln -sf /etc/nginx/sites-available/odoo /etc/nginx/sites-enabled/odoo
nginx -t && systemctl reload nginx

# TLS: apt-get install certbot python3-certbot-nginx && certbot --nginx -d $DOMAIN
