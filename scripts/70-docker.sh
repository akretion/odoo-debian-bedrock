#!/usr/bin/env bash
# 70-docker (LAYER 2): docker engine + docky on the bedrock-prepped host.
# The Odoo app then runs in containers (docky-odoo-template-shared);
# the same pinned addon set as layer 1 feeds the image build.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

install -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") $(. /etc/os-release; echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

# docky: Akretion's docker-compose wrapper
pipx install docky 2>/dev/null || pip3 install --user docky || true

# app user runs the containers (matches our ansible/docky convention):
id app &>/dev/null || adduser --disabled-password --gecos "" app
usermod -aG docker app
