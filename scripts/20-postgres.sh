#!/usr/bin/env bash
# 20-postgres: distro postgresql. For PGDG (newer major), set PGDG=1.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if [ "${PGDG:-0}" = 1 ]; then
  . /etc/os-release
  install -d /usr/share/postgresql-common/pgdg
  wget -qO /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
    https://www.postgresql.org/media/keys/ACCC4CF8.asc
  echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] http://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list
  apt-get update -qq
fi

apt-get install -y -qq postgresql postgresql-client libpq-dev

# shellcheck source=lib-instance.sh
source "$(dirname "$0")/lib-instance.sh"
configure_pg_tuning

# Odoo deb's postinst creates the 'odoo' role; if it ran before postgres
# was up (or postgres was installed after), ensure the role exists:
su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='odoo'\" | grep -q 1 || createuser -d -R -S odoo" || true
