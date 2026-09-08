#!/usr/bin/env bash
# 80-project: attach a customer project (airandme/favex-style repo) to
# a bedrock layer-1 host.
#
#   PROJECT_NAME=airandme PROJECT_REPO=git@github.com:akretion/airandme.git \
#     bash scripts/80-project.sh
#
# Layout (unchanged from our docker convention):
#   /home/app/<project>/            git clone, owned by the 'app' user
#     odoo/links                    ak-built symlink farm (prepend)
#     odoo/local-src                customer modules
#     odoo/external-src/<repo>      OCA/third-party clones
#     odoo/requirements.txt         python/odoo-addon pins -> venv
#
# Identity model: 'app' owns and deploys the code (SSH access);
# 'odoo' (from the deb) only READS it at runtime. One project per
# bedrock host — multi-project hosts are layer 2 (docker/docky).
set -euo pipefail
: "${PROJECT_NAME:?set PROJECT_NAME (e.g. airandme)}"
: "${PROJECT_REPO:?set PROJECT_REPO (git url)}"
: "${PROJECT_BRANCH:=}"

VENV=/usr/lib/odoo/venv
HOME_DIR=/home/app
PROJ=$HOME_DIR/$PROJECT_NAME

id app &>/dev/null || adduser --disabled-password --gecos "" app

if [ ! -d "$PROJ/.git" ]; then
  su -s /bin/bash app -c "git clone ${PROJECT_BRANCH:+--branch $PROJECT_BRANCH} $PROJECT_REPO $PROJ"
else
  su -s /bin/bash app -c "git -C $PROJ pull --ff-only"
fi

# odoo must read the code (default umask 022 already makes it
# world-readable; enforce defensively):
chmod -R a+rX "$PROJ/odoo"

# python deps -> the bedrock venv (odoo-addon-* resolve via the odoo
# stub; git+ssh/https URLs also fine):
if [ -f "$PROJ/odoo/requirements.txt" ]; then
  "$VENV/bin/pip" install -r "$PROJ/odoo/requirements.txt"
fi

# Build the addons_path: project dirs first (customer code shadows),
# then the bedrock venv, then the deb core (last two already in
# /etc/odoo/odoo.conf — we only prepend).
ADDONS=""
[ -d "$PROJ/odoo/links" ]     && ADDONS="$PROJ/odoo/links,"
[ -d "$PROJ/odoo/local-src" ] && ADDONS="$ADDONS$PROJ/odoo/local-src,"
if [ -d "$PROJ/odoo/external-src" ]; then
  for repo in "$PROJ/odoo/external-src"/*/; do
    [ -d "$repo" ] && ADDONS="$ADDONS${repo%/},"
  done
fi

# idempotent odoo.conf update: drop previous project block, append fresh
sed -i '/^# bedrock-project-begin/,/^# bedrock-project-end/d' /etc/odoo/odoo.conf
cat >> /etc/odoo/odoo.conf <<EOF
# bedrock-project-begin ($PROJECT_NAME)
addons_path = ${ADDONS}$(grep -m1 '^addons_path' /etc/odoo/odoo.conf | cut -d= -f2- | tr -d ' ')
dbfilter = ^${PROJECT_NAME}.*
# bedrock-project-end
EOF
chown odoo:odoo /etc/odoo/odoo.conf

systemctl restart odoo 2>/dev/null || \
  echo "no systemd here — restart odoo manually (proot/container testbed)"
echo "project $PROJECT_NAME attached: addons prepended, dbfilter=^${PROJECT_NAME}.*"
