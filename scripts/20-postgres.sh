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

# NEVER install the bare 'postgresql' metapackage with PGDG enabled: on
# apt.postgresql.org it is the newest major and it depends on
# postgresql-all, which pulls EVERY supported major (10..18), the pl
# extensions for each, postgresql-server-dev-all and the LLVM/clang
# toolchain (~2.5 GB) -- and still creates no cluster when one already owns
# port 5432. Install one explicit major instead.
if [ "${PGDG:-0}" = 1 ]; then
  apt-get install -y -qq postgresql-common postgresql-client-common libpq-dev
  if [ -z "${PG_MAJOR:-}" ]; then
    PG_MAJOR=$(apt-cache search --names-only '^postgresql-1[0-9]$' \
      | grep -oE 'postgresql-1[0-9]' | grep -oE '1[0-9]' | sort -n | tail -1)
  fi
  echo "installing PostgreSQL $PG_MAJOR (PGDG)"
  apt-get install -y -qq "postgresql-$PG_MAJOR" "postgresql-client-$PG_MAJOR"
else
  apt-get install -y -qq postgresql postgresql-client libpq-dev
fi

# Existing clusters are never touched by this script. A major bump needs an
# explicit pg_upgradecluster (README "PostgreSQL major upgrade"), never an
# implicit apt install.
if pg_lsclusters --no-header 2>/dev/null | grep -q .; then
  echo "existing clusters (left as-is):"
  pg_lsclusters
fi

# shellcheck source=lib-instance.sh
source "$(dirname "$0")/lib-instance.sh"
configure_pg_tuning

# Odoo deb's postinst creates the 'odoo' role; if it ran before postgres
# was up (or postgres was installed after), ensure the role exists:
su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='odoo'\" | grep -q 1 || createuser -d -R -S odoo" || true

# ... and let that role actually log in over the unix socket (peer auth).
ensure_pg_peer_role "${PG_RUNTIME_ROLE:-odoo}"
