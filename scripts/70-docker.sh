#!/usr/bin/env bash
# 70-docker (LAYER 2): docker engine on the bedrock-prepped host.
# The Odoo app then runs in containers (docky-odoo-template-shared for the
# docker option, a hosted-apps control plane for the paas option); the same
# pinned addon set as layer 1 feeds the image build.
#
#   DOCKY=1 (default)  also install docky (the compose wrapper of the docker
#                      option) — it is useless to a hosted-apps host, where the
#                      build happens in the image, so `bin/bedrock --with-paas`
#                      passes DOCKY=0.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
: "${DOCKY:=1}"
# docky install spec. The PyPI release ships `[bdist_wheel] python_tag = py310`
# in setup.cfg, which modern pip converts to the invalid tag `py34+` and then
# refuses ("Built wheel for docky is invalid: Invalid wheel filename (invalid
# tag component)"), taking the whole layer down on Ubuntu 26.04 / Python 3.14.
# Until a fixed release is on PyPI, install the branch that drops it. Set
# DOCKY_SPEC=docky once that release exists; pin the commit
# (git+https://github.com/akretion/docky@714eb68) for a frozen install.
: "${DOCKY_SPEC:=git+https://github.com/akretion/docky@fix-py3-wheel-tag}"

install -d /etc/apt/keyrings
. /etc/os-release
# --batch --yes: on a re-run the keyring exists and gpg would stop to ask for
# confirmation on /dev/tty (absent under setsid/CI), killing the layer with
# "gpg: cannot open '/dev/tty'" before anything else happens.
curl -fsSL "https://download.docker.com/linux/$ID/gpg" \
  | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$ID $VERSION_CODENAME stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

# docky: Akretion's docker-compose wrapper. Installed via pipx into the
# shared /opt/pipx home so the `app` user (which runs the containers) sees
# it. `ak` is already installed by 11-tools.sh on every install.
# shellcheck source=lib-instance.sh
source "$(dirname "$0")/lib-instance.sh"
if [ "$DOCKY" = 1 ]; then
  install_pipx_tool "$DOCKY_SPEC" docky
else
  echo "DOCKY=0: skipping docky (a hosted-apps host builds the image, it does not run compose)"
fi

# app user runs the containers (matches our ansible/docky convention):
id app &>/dev/null || adduser --disabled-password --gecos "" app
usermod -aG docker app
ensure_deploy_key app

# Make the HOST postgres reachable from containers over TCP (recommended
# over socket mounting — see README "Docker + host Postgres"). Containers
# connect to host.docker.internal (the bridge gateway), so postgres must
# listen on it and pg_hba must allow the docker subnet. External 5432 stays
# closed by ufw (10-base.sh) and pg_hba scoping.
configure_pg_for_docker

echo "layer 2 ready. For each docker project, create its PG role + db:"
echo "  DB_NAME=<project> bash scripts/72-pg-docker-user.sh"
echo "  (writes /etc/odoo/db-credentials-<project>.env: DB_* for the app, PG* for psql/CI)"

