#!/usr/bin/env bash
# 80-project: attach a customer project (airandme/favex-style repo) to the
# PROD instance. For staging, see 81-staging.sh (same lib, different defaults).
#
#   PROJECT_NAME=airandme PROJECT_REPO=git@github.com:akretion/airandme.git \
#     bash scripts/80-project.sh
#
# Identity model: 'app' owns and deploys the code (SSH); 'odoo' (deb user)
# only READS it. One project per layer-1 host — multi-project = layer 2.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
: "${ODOO_VERSION:=18.0}"
: "${PROJECT_NAME:?set PROJECT_NAME (e.g. airandme)}"
: "${PROJECT_REPO:?set PROJECT_REPO (git url)}"
: "${PROJECT_BRANCH:=}"

# These are the interface consumed by lib-instance.sh's attach_project().
# shellcheck disable=SC2034
APP_USER=app
# shellcheck disable=SC2034
RUNTIME_USER=odoo
# shellcheck disable=SC2034
VENV=/usr/lib/odoo/venv
ODOO_CONF=/etc/odoo/odoo.conf
DBFILTER="^${PROJECT_NAME}.*"
# shellcheck disable=SC2034
UNIT=odoo

# shellcheck source=lib-instance.sh
source "$(dirname "$0")/lib-instance.sh"

attach_project
echo "project $PROJECT_NAME attached to $ODOO_CONF (dbfilter=$DBFILTER)"
