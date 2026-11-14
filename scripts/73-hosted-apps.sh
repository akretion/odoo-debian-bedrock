#!/usr/bin/env bash
# 73-hosted-apps (LAYER 2b): make the host ready to run hosted applications —
# a mini-PaaS control plane creates one container per app, the HOST postgres is
# the database, the HOST nginx serves the apps.
#
# This layer deliberately ships NO control plane: the installer is a separate,
# private artefact. Everything a control plane needs from the host is here, so
# pointing HOSTED_APPS_INSTALLER at one works out of the box:
#
#   HOSTED_APPS_INSTALLER=/root/install-control-plane.sh bash scripts/73-hosted-apps.sh
#
# Without it the layer only prepares and verifies the host, and prints what is
# still missing. Re-run it any time (idempotent).
#
# What it guarantees:
#   * containers can reach the host cluster over TCP (listen_addresses + pg_hba
#     rule inserted before the catch-all rejects, see configure_pg_for_docker);
#   * ufw lets the docker subnet reach 5432 while keeping 5432 closed to the
#     world — 10-base.sh only opens 22/80/443, and without this rule the
#     symptom is `connection timed out`, which reads like a dead postgres;
#   * the deploy user (`app`) exists, is in the docker group and owns the
#     storage root the apps mount (/home/app/data/<app>);
#   * the host nginx keeps its vhosts in sites-enabled/ while the control plane
#     owns conf.d/ — the two never rewrite each other.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

: "${HOSTED_APPS_INSTALLER:=}"

# shellcheck source=lib-instance.sh
source "$(dirname "$0")/lib-instance.sh"

echo "=== containers -> host postgres"
configure_pg_for_docker
if docker network inspect bridge >/dev/null 2>&1; then
  gw=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)
  [ -n "$gw" ] && echo "docker bridge gateway: $gw (containers: --add-host host.docker.internal:host-gateway)"
fi

echo "=== ufw: docker subnet -> 5432 only"
if command -v ufw >/dev/null 2>&1; then
  ufw allow from 172.16.0.0/12 to any port 5432 proto tcp >/dev/null || true
  ufw status | grep -E '5432' || true
fi

echo "=== deploy user + storage root"
id app &>/dev/null || adduser --disabled-password --gecos "" app
if getent group docker >/dev/null 2>&1; then
  usermod -aG docker app
else
  echo "no 'docker' group: run 70-docker.sh before this layer" >&2
fi
install -d -o app -g app -m 0755 /home/app/data
ensure_deploy_key app

echo "=== control plane"
if [ -n "$HOSTED_APPS_INSTALLER" ]; then
  # The installer is a private artefact (a local path or an already downloaded
  # file); this layer neither vendors it nor pins its version.
  [ -r "$HOSTED_APPS_INSTALLER" ] || { echo "ERROR: HOSTED_APPS_INSTALLER=$HOSTED_APPS_INSTALLER is not readable" >&2; exit 1; }
  # shellcheck disable=SC1090
  bash "$HOSTED_APPS_INSTALLER"
else
  echo "no HOSTED_APPS_INSTALLER given: host prepared, control plane NOT installed."
  echo "  HOSTED_APPS_INSTALLER=/path/to/private/installer.sh bash scripts/73-hosted-apps.sh"
fi

echo "=== nginx coexistence"
if ! command -v nginx >/dev/null 2>&1; then
  echo "nginx not installed yet: the control plane brings it, or set DOMAIN and run 50-nginx.sh"
else
  if pgrep -f "nginx: master" >/dev/null; then echo "nginx master: running"; else echo "nginx master: NOT running"; fi
  if [ -d /etc/nginx/sites-enabled ]; then
    echo "our vhosts (sites-enabled/), the control plane owns conf.d/:"
    ls -1 /etc/nginx/sites-enabled/ 2>/dev/null | sed 's/^/  /'
  fi
  nginx -t 2>&1 | tail -2
fi

cat <<'TXT'

Per hosted app (the Odoo specifics no control plane can know):
  * publish the app's HTTP port on the proxy and keep an https entry:
        http:80:8069  https:443:8069  http:18072:8072   (ports are REPLACED, not merged)
  * raise the proxy limits: client body 200m, proxy read timeout 720s
  * route /websocket to the 8072 (gevent) port: the stock vhost only proxies "/",
    so chat and the bus are otherwise unreachable
  * mount the filestore on /data/odoo with the host `app` uid as LOCAL_USER_ID,
    storage root /home/app/data/<app> (60-backup.sh discovers that path)
  * let the container resolve the host: docker-options --add-host
    host.docker.internal:host-gateway
  * DB_* come from /etc/odoo/db-credentials-<db>.env (72-pg-docker-user.sh);
    the database owner MUST be the app's DB_USER, or Odoo lists no database
  * declare a health check on /web/health in the image: without it the app
    receives traffic ~10s after start, while the registry is still loading
  * keep 5432 and the chat port closed to the world: ufw already does, prove it
    with `ss -ltnp` rather than trusting the status output
TXT

echo "=== bedrock: hosted-apps layer ready ==="
