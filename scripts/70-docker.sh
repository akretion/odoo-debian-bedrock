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
PGVER=$(ls /etc/postgresql | head -1)
PGCONF="/etc/postgresql/$PGVER/main/postgresql.conf"
PGHBA="/etc/postgresql/$PGVER/main/pg_hba.conf"

if grep -qE '^[#]?listen_addresses' "$PGCONF"; then
  sed -i -E "s|^[#]?listen_addresses.*|listen_addresses = '*'|" "$PGCONF"
else
  echo "listen_addresses = '*'" >> "$PGCONF"
fi

# docker bridge subnets (default 172.17/16 + custom 172.18..172.31/16)
grep -q "172.16.0.0/12" "$PGHBA" || cat >> "$PGHBA" <<'EOF'
# odoo-debian-bedrock: docker containers reach host postgres over TCP
host    all             all             172.16.0.0/12           scram-sha-256
EOF

pg_ctlcluster "$PGVER" main reload 2>/dev/null || service postgresql reload 2>/dev/null || true

echo "layer 2 ready. For each docker project, create its PG role + db:"
echo "  DB_NAME=<project> DB_PASSWORD=<secret> bash scripts/72-pg-docker-user.sh"

