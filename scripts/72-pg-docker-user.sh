#!/usr/bin/env bash
# 72-pg-docker-user: create a PG role (+ SCRAM password) and database for ONE
# container project (docky, docker compose, dokku) to reach host postgres over
# TCP, and write the credentials file the container consumes.
#
#   DB_NAME=myproj bash scripts/72-pg-docker-user.sh            # password generated
#   DB_NAME=myproj DB_USER=myproj_stg bash scripts/72-pg-docker-user.sh
#   PGDATABASE=myproj PGUSER=myproj PGPASSWORD=... bash scripts/72-pg-docker-user.sh
#
# BOTH naming schemes are accepted (PG* wins when both are set) because the
# docky compose files take PGHOST/PGPORT/PGDATABASE/PGUSER/PGPASSWORD from the
# deployment env and map them to the DB_* names the Odoo container reads. Using
# one name for input and another for output is exactly the confusion this
# script is meant to remove.
#
# Idempotent: re-running RESETS the password and rewrites the credentials file,
# so the database and the file can never drift apart.
set -euo pipefail

# shellcheck source=lib-instance.sh
source "$(dirname "$0")/lib-instance.sh"

DB_NAME="${DB_NAME:-${PGDATABASE:-}}"
DB_USER="${DB_USER:-${PGUSER:-$DB_NAME}}"
: "${DB_NAME:?set DB_NAME (or PGDATABASE)}"
DB_PASSWORD="${DB_PASSWORD:-${PGPASSWORD:-}}"
CREDS_FILE="${CREDS_FILE:-/etc/odoo/db-credentials-${DB_NAME}.env}"
DB_HOST_FOR_DOCKER="${DB_HOST_FOR_DOCKER:-host.docker.internal}"

if [ -z "$DB_PASSWORD" ]; then
  DB_PASSWORD=$(openssl rand -hex 24)
  echo "generated a password for role '$DB_USER' (written to $CREDS_FILE only)"
fi

# Role: LOGIN + CREATEDB (Odoo may create test databases), never SUPERUSER.
# No peer path here: a container cannot use peer auth (its uid never matches).
su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'\" | grep -q 1 || psql -q -c \"CREATE ROLE \\\"$DB_USER\\\" LOGIN CREATEDB\""
set_role_password "$DB_USER" "$DB_PASSWORD"

# Database owned by that role (created only when missing: never touch data).
su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='$DB_NAME'\" | grep -q 1 || createdb -O \"$DB_USER\" \"$DB_NAME\""

write_db_credentials "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$CREDS_FILE" "$DB_HOST_FOR_DOCKER"
chmod 0640 "$CREDS_FILE"
# The deploy user runs docky, so it must be able to read the file; root keeps
# ownership so the secret is never writable by the app user.
chgrp app "$CREDS_FILE" 2>/dev/null || true

echo "container PG access ready:"
echo "  db=$DB_NAME user=$DB_USER host=$DB_HOST_FOR_DOCKER port=5432"
echo "  credentials: $CREDS_FILE (0640, group app)"
echo "docky/docker compose: point PG* at it, the compose maps them to DB_*."
echo "dokku: set -a; . $CREDS_FILE; set +a; \\"
echo "  dokku config:set <app> DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD DB_FILTER"
