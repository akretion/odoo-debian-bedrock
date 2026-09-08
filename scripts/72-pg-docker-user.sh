#!/usr/bin/env bash
# 72-pg-docker-user: create a PG role (+ password) and database for one
# docker/docky project to reach host postgres over TCP.
#
#   DB_NAME=myproj DB_PASSWORD=<secret> bash scripts/72-pg-docker-user.sh
#   DB_NAME=myproj DB_USER=myproj_staging DB_PASSWORD=... bash scripts/72-pg-docker-user.sh
#
# The container then uses: DB_HOST=host.docker.internal, this DB_USER and
# DB_PASSWORD (see README "Docker + host Postgres"). Idempotent.
set -euo pipefail
: "${DB_NAME:?set DB_NAME}"
: "${DB_USER:=$DB_NAME}"
: "${DB_PASSWORD:?set DB_PASSWORD}"

su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'\" | grep -q 1 || psql -c \"CREATE ROLE \\\"$DB_USER\\\" LOGIN CREATEDB PASSWORD '$DB_PASSWORD'\""
su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='$DB_NAME'\" | grep -q 1 || createdb -O \"$DB_USER\" \"$DB_NAME\""

echo "docker PG access ready: host=host.docker.internal port=5432 db=$DB_NAME user=$DB_USER"
