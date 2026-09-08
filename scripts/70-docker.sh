#!/usr/bin/env bash
# 70-docker (LAYER 2): docker engine + docky on the bedrock-prepped host.
# The Odoo app then runs in containers (docky-odoo-template-shared);
# the same pinned addon set as layer 1 feeds the image build.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

install -d /etc/apt/keyrings
. /etc/os-release
curl -fsSL "https://download.docker.com/linux/$ID/gpg" \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$ID $VERSION_CODENAME stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

# docky: Akretion's docker-compose wrapper
pipx install docky 2>/dev/null || pip3 install --user docky || true

# app user runs the containers (matches our ansible/docky convention):
id app &>/dev/null || adduser --disabled-password --gecos "" app
usermod -aG docker app

# Make the HOST postgres reachable from containers over TCP (recommended
# over socket mounting — see README "Docker + host Postgres"). Containers
# connect to host.docker.internal (the bridge gateway), so postgres must
# listen on it and pg_hba must allow the docker subnet. External 5432 stays
# closed by ufw (10-base.sh) and pg_hba scoping.
# shellcheck source=lib-instance.sh
source "$(dirname "$0")/lib-instance.sh"
configure_pg_for_docker

echo "layer 2 ready. For each docker project, create its PG role + db:"
echo "  DB_NAME=<project> DB_PASSWORD=<secret> bash scripts/72-pg-docker-user.sh"

