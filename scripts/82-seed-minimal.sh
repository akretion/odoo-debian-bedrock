#!/usr/bin/env bash
# 82-seed: nightly neutralized seed of production, kept as a TEMPLATE.
# Clones are made with `createdb -T <seed>` (seconds, disk-thin) instead of
# loading a dump, and the neutralization happens once, here.
# Config: /etc/odoo-seed.conf — SEED_SRC, SEED_DB, SEED_ROLE, SEED_HOOKS (dir of
# *.sql applied after the base), optional SEED_URL, ODOO_PY.
set -euo pipefail
[ -r /etc/odoo-seed.conf ] && . /etc/odoo-seed.conf
: "${SEED_SRC:?set SEED_SRC} ${SEED_DB:?set SEED_DB} ${SEED_ROLE:?set SEED_ROLE}"
SU=(runuser -u postgres --)
CORE=$("${ODOO_PY:-python3}" -c 'import os, odoo.addons.base as b; print(os.path.dirname(b.__file__) + "/data/neutralize.sql")')
"${SU[@]}" pg_dump -Fc "$SEED_SRC" > "/var/backups/${SEED_DB}.dump"
"${SU[@]}" psql -q -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS \"${SEED_DB}_new\" WITH (FORCE)" \
    -c "CREATE DATABASE \"${SEED_DB}_new\" OWNER \"$SEED_ROLE\" TEMPLATE template0"
for e in $("${SU[@]}" psql -tA -d "$SEED_SRC" -c "SELECT extname FROM pg_extension WHERE extname <> 'plpgsql'"); do
    "${SU[@]}" psql -q -d "${SEED_DB}_new" -c "CREATE EXTENSION IF NOT EXISTS \"$e\"" 2>/dev/null
done
# extensions are cluster objects: created by postgres above, so the TOC finds them
"${SU[@]}" pg_restore --no-owner --no-acl --role="$SEED_ROLE" -d "${SEED_DB}_new" < "/var/backups/${SEED_DB}.dump" \
    || echo "pg_restore reported non-fatal errors (extension/comment ownership), continuing"
"${SU[@]}" psql -q -v ON_ERROR_STOP=1 -d "${SEED_DB}_new" -f "$CORE" \
    -c "UPDATE ir_cron SET active = false"
if [ -n "${SEED_HOOKS:-}" ]; then
    for f in "$SEED_HOOKS"/*.sql; do
        [ -e "$f" ] && "${SU[@]}" psql -q -v ON_ERROR_STOP=1 -d "${SEED_DB}_new" -f "$f"
    done
fi
"${SU[@]}" psql -q -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS \"$SEED_DB\" WITH (FORCE)" \
    -c "ALTER DATABASE \"${SEED_DB}_new\" RENAME TO \"$SEED_DB\""
echo "seed $SEED_DB rebuilt from $SEED_SRC at $(date -Is)"
