#!/usr/bin/env bash
# 82-seed: nightly neutralized seed of production, kept as a TEMPLATE.
# Clones are made with `createdb -T <seed>` (seconds, disk-thin) instead of
# loading a dump, and the neutralization happens once, here.
#
# Deliberately SHALLOW and PLUGGABLE: the series' own base/data/neutralize.sql,
# every cron off, every outgoing mail server off, incoming mail off, then the
# project's own hooks. Anything richer (payment providers, filestore, ribbon,
# fiscal environment, per-module neutralize.sql) belongs to the tooling that
# owns the environments — fan extension could providers
# bin/seed, which ships those files with itself and keeps this layer untouched.
# Do not grow a second copy of them here: two copies of the same SQL is how a
# fix lands in one and silently not in the other.
#
# Config: /etc/odoo-seed.conf — SEED_SRC, SEED_DB, SEED_ROLE, SEED_HOOKS (dir of
# *.sql applied after the base), optional SEED_URL, ODOO_PY.
set -euo pipefail
[ -r /etc/odoo-seed.conf ] && . /etc/odoo-seed.conf
: "${SEED_SRC:?set SEED_SRC} ${SEED_DB:?set SEED_DB} ${SEED_ROLE:?set SEED_ROLE}"
SU=(runuser -u postgres --)
CORE=$("${ODOO_PY:-python3}" -c 'import os, odoo.addons.base as b; print(os.path.dirname(b.__file__) + "/data/neutralize.sql")')
"${SU[@]}" pg_dump -Fc "$SEED_SRC" >"/var/backups/${SEED_DB}.dump"
"${SU[@]}" psql -q -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS \"${SEED_DB}_new\" WITH (FORCE)" \
  -c "CREATE DATABASE \"${SEED_DB}_new\" OWNER \"$SEED_ROLE\" TEMPLATE template0"
for e in $("${SU[@]}" psql -tA -d "$SEED_SRC" -c "SELECT extname FROM pg_extension WHERE extname <> 'plpgsql'"); do
  "${SU[@]}" psql -q -d "${SEED_DB}_new" -c "CREATE EXTENSION IF NOT EXISTS \"$e\"" 2>/dev/null
done
# extensions are cluster objects: created by postgres above, so the TOC finds them
"${SU[@]}" pg_restore --no-owner --no-acl --role="$SEED_ROLE" -d "${SEED_DB}_new" <"/var/backups/${SEED_DB}.dump" ||
  echo "pg_restore reported non-fatal errors (extension/comment ownership), continuing"
# The series' own file, then the two things it does NOT guarantee:
#   * crons: core turns the business ones off but keeps base.autovacuum;
#   * OUTGOING MAIL: core replaces the real SMTP with a dummy
#     ("neutralization - disable emails", host `invalid`) that it leaves ACTIVE,
#     so a copy still tries to send. Turning them ALL off is the safer default,
#     and it must run AFTER core's file or it is undone by the dummy's creation.
# Both statements only use columns that exist from 16 to 20; the optional tables
# are guarded, so the same file runs unchanged on any series.
"${SU[@]}" psql -q -v ON_ERROR_STOP=1 -d "${SEED_DB}_new" \
  -f "$CORE" \
  -c "UPDATE ir_cron SET active = false" \
  -c "UPDATE ir_mail_server SET active = false" \
  -c 'DO $$ BEGIN
          IF to_regclass('"'"'fetchmail_server'"'"') IS NOT NULL THEN
            EXECUTE '"'"'UPDATE fetchmail_server SET active = false'"'"';
          END IF;
        END $$'
if [ -n "${SEED_HOOKS:-}" ]; then
  for f in "$SEED_HOOKS"/*.sql; do
    [ -e "$f" ] && "${SU[@]}" psql -q -v ON_ERROR_STOP=1 -d "${SEED_DB}_new" -f "$f"
  done
fi
"${SU[@]}" psql -q -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS \"$SEED_DB\" WITH (FORCE)" \
  -c "ALTER DATABASE \"${SEED_DB}_new\" RENAME TO \"$SEED_DB\""
echo "seed $SEED_DB rebuilt from $SEED_SRC at $(date -Is)"
