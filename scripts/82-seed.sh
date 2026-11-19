#!/usr/bin/env bash
# 82-seed: nightly NEUTRALIZED seed of a production database, kept on the SAME
# PostgreSQL cluster as a TEMPLATE.
#
# Why a template and not a dump: every staging database, every branch env and
# every CI run must come from `createdb -T <seed>` (seconds, no dump to load, no
# second neutralization to remember). Production is read once per night, the
# neutralization happens ONCE on the seed, and nothing that clones it can
# inherit a live cron, a live SMTP server or a production URL.
#
# This script is deliberately the BASIC half, and it is generic (host PostgreSQL
# over the unix socket, no container runtime): dump -> restore into <seed>_new ->
# neutralize -> install SEED_MODULES -> swap -> optional re-clone of dependent
# DBs. Anything richer (a database inside a container runtime, filestore
# hardlinked into app storage, per-branch switching, HTTP verification) belongs
# to the application-image tooling, which reads the SAME two SQL files.
#
# Neutralization is THREE layers, in this order:
#   1. the series' OWN base/data/neutralize.sql, taken from the installed Odoo —
#      never a vendored copy, so 16 -> 20 stays correct by construction (18 adds
#      the webhook update, 19 adds the SMTP-credential and database.secret
#      rewrites, 20 will bring its own);
#   2. share/neutralize-extras.sql — the gaps core leaves for a COPY (queued
#      jobs/mail, fetchmail, payment providers in test, the seed URL, the
#      environment ribbon), guarded per table so a missing module is a no-op;
#   3. the project hook_dir (*.sql), where project facts live.
# Then neutralize-filestore.sql makes the seed filestore-FREE: createdb -T copies
# the database, not the directory of files, so a clone inheriting attachment rows
# would answer 500 on every compiled bundle. Asset bundles are deleted (each clone
# regenerates them from its own code) and business attachments lose their pointer
# instead of shipping the customer's documents onto a staging host.
#
#   bash scripts/82-seed.sh                  # install helper + config + cron
#   bash scripts/82-seed.sh --run tecservice # refresh one seed now
#   bash scripts/82-seed.sh --run all        # refresh every configured seed
#
# Configuration: /etc/odoo-seed.conf, created on first run and NEVER overwritten
# (same contract as 60-backup.sh). One line per seed:
#
#   SEED_TARGETS="name|source_db|seed_db|role|url|hook_dir"
#
#   name      label used for the dump filename and log lines
#   source_db production database, read-only (pg_dump over the unix socket)
#   seed_db   template database to (re)build
#   role      PG role that owns the seed and the clones made from it
#   url       web.base.url written into the seed
#   hook_dir  optional directory of *.sql applied after the base neutralization
#
# Other knobs: SEED_MODULES (installed on the seed with a real `odoo -i`, so
# clones inherit views/assets — default web_environment_ribbon), SEED_LABEL /
# SEED_COLOR (ribbon look), SEED_CLONE_DBS (space-separated databases re-cloned
# from the seed after each refresh), SEED_SOURCE_FILESTORE / SEED_FILESTORE_ROOT
# (OFF by default: a seed carries NO production file, see below), SEED_RETENTION.
#
# A project that wants MORE neutralization (fiscal environment, discuss
# history, payment settings, third-party URLs) writes it in its hook_dir — no
# change to this script. The full `odoo neutralize` (every installed module's
# data/neutralize.sql) is opt-in: SEED_MODULE_SQL=yes.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_SRC="${SELF_DIR%/scripts}/share/neutralize-extras.sql"
SQL_DST=/usr/local/lib/odoo-seed/neutralize-extras.sql
RIBBON_SRC="${SELF_DIR%/scripts}/share/neutralize-ribbon.sql"
RIBBON_DST=/usr/local/lib/odoo-seed/neutralize-ribbon.sql
FS_SRC="${SELF_DIR%/scripts}/share/neutralize-filestore.sql"
FS_DST=/usr/local/lib/odoo-seed/neutralize-filestore.sql
HELPER=/usr/local/bin/odoo-seed-refresh
CONF=/etc/odoo-seed.conf
DUMP_DIR=/var/backups/odoo-seed

echo "--- helper + neutralization SQL"
install -d -m 0755 "$(dirname "$SQL_DST")" "$DUMP_DIR"
[ -f "$SQL_SRC" ] || { echo "ABORT: missing $SQL_SRC" >&2; exit 1; }
install -m 0644 "$SQL_SRC" "$SQL_DST"
[ -f "$RIBBON_SRC" ] && install -m 0644 "$RIBBON_SRC" "$RIBBON_DST"
[ -f "$FS_SRC" ] && install -m 0644 "$FS_SRC" "$FS_DST"

cat > "$HELPER" <<'EOF'
#!/usr/bin/env bash
# Installed by odoo-debian-bedrock (scripts/82-seed.sh).
# CONFIGURE IN /etc/odoo-seed.conf — this file is rewritten on bedrock update.
set -euo pipefail

CONF=/etc/odoo-seed.conf
SQL=/usr/local/lib/odoo-seed/neutralize-extras.sql
SQL_RIBBON=/usr/local/lib/odoo-seed/neutralize-ribbon.sql
SQL_FS=/usr/local/lib/odoo-seed/neutralize-filestore.sql
DUMP_DIR=/var/backups/odoo-seed

SEED_TARGETS=""
SEED_MODULES="web_environment_ribbon"
SEED_LABEL="STAGING"
SEED_COLOR="rgba(255,153,0,.6)"
SEED_CLONE_DBS=""
SEED_MODULE_SQL="no"
SEED_FILESTORE="no"
SEED_SOURCE_FILESTORE="/var/lib/odoo/.local/share/Odoo/filestore"
SEED_FILESTORE_ROOT="/var/lib/odoo/.local/share/Odoo/filestore"
SEED_RETENTION=3
ODOO_BIN=/usr/bin/odoo
ODOO_CONF=/etc/odoo/odoo.conf
ODOO_USER=odoo
SEED_CORE_SQL=""
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"

log() { echo "$(date '+%F %T') $*"; }
die() { echo "$(date '+%F %T') ABORT: $*" >&2; exit 1; }
psql_pg() { runuser -u postgres -- psql -v ON_ERROR_STOP=1 "$@"; }
as_odoo() { su -s /bin/bash "$ODOO_USER" -c "$*"; }
# The series' own base/data/neutralize.sql. Ask the installation instead of
# hardcoding a layout: venv overlay, plain deb, and a project venv all differ.
core_sql() {
    local py=/usr/bin/python3 p
    [ -x /usr/lib/odoo/venv/bin/python3 ] && py=/usr/lib/odoo/venv/bin/python3
    p="$("$py" -c 'import os, odoo.addons.base as b; print(os.path.join(os.path.dirname(b.__file__), "data", "neutralize.sql"))' 2>/dev/null | tail -1)"
    [ -n "$p" ] || p=/usr/lib/python3/dist-packages/odoo/addons/base/data/neutralize.sql
    [ -r "$p" ] || return 1
    printf '%s' "$p"
}

refresh_one() {
    local line="$1" name src seed role url hooks
    IFS='|' read -r name src seed role url hooks <<< "$line"
    [ -n "$name" ] && [ -n "$src" ] && [ -n "$seed" ] && [ -n "$role" ] \
        || die "bad SEED_TARGETS line: $line"

    log "[$name] dump ${src} (read-only)"
    local dump="${DUMP_DIR}/${name}-$(date +%Y%m%d-%H%M%S).dump"
    runuser -u postgres -- pg_dump -Fc "$src" > "$dump"
    log "[$name] dump: $dump ($(du -h "$dump" | cut -f1))"

    log "[$name] restore into ${seed}_new"
    psql_pg -q -c "DROP DATABASE IF EXISTS \"${seed}_new\" WITH (FORCE)"
    psql_pg -q -c "CREATE DATABASE \"${seed}_new\" OWNER \"${role}\" TEMPLATE template0"
    runuser -u postgres -- pg_restore --no-owner --no-acl --role="$role" \
        -d "${seed}_new" < "$dump"

    local core
    if [ -n "$SEED_CORE_SQL" ]; then core="$SEED_CORE_SQL"; else core="$(core_sql)" || core=""; fi
    if [ -n "$core" ]; then
        log "[$name] neutralize (core): $core"
        psql_pg -q -d "${seed}_new" -f "$core"
    else
        log "[$name] WARNING: base/data/neutralize.sql not found (set SEED_CORE_SQL)"
    fi
    log "[$name] neutralize (extras): $(basename "$SQL")"
    psql_pg -q -d "${seed}_new" -v seed_url="$url" \
        -v seed_label="$SEED_LABEL" -v seed_color="$SEED_COLOR" -f "$SQL"
    if [ -n "${hooks:-}" ] && [ -d "$hooks" ]; then
        local f
        for f in "$hooks"/*.sql; do
            [ -e "$f" ] || continue
            log "[$name] hook $(basename "$f")"
            psql_pg -q -d "${seed}_new" -v seed_url="$url" -f "$f"
        done
    fi
    if [ "$SEED_MODULE_SQL" = yes ]; then
        # opt-in: EVERY installed module's data/neutralize.sql (rewrites a lot)
        log "[$name] odoo neutralize (all installed modules)"
        as_odoo "$ODOO_BIN neutralize -c $ODOO_CONF -d ${seed}_new"
    fi

    log "[$name] swap ${seed}"
    psql_pg -q -c "DROP DATABASE IF EXISTS \"${seed}\" WITH (FORCE)"
    psql_pg -q -c "ALTER DATABASE \"${seed}_new\" RENAME TO \"${seed}\""
    psql_pg -q -c "ALTER DATABASE \"${seed}\" OWNER TO \"${role}\""

    # Modules the neutralization QUEUED (or that production keeps uninstalled)
    # need a real `odoo -i` ON THE SEED: SQL can only set a state, the views and
    # assets come from the install, and every clone made afterwards inherits it.
    if [ -n "$SEED_MODULES" ]; then
        log "[$name] install on seed: $SEED_MODULES"
        # shellcheck disable=SC2086
        as_odoo "$ODOO_BIN -c $ODOO_CONF -d $seed -i $SEED_MODULES \
                 --stop-after-init --no-http --workers=0" \
            || log "[$name] WARNING: module install failed (is $SEED_MODULES in addons_path?)"
    fi
    # The ribbon's LOOK is UPDATE-only and comes AFTER the install: the module's
    # data file CREATES ir_config_parameter('ribbon.name'), so writing it earlier
    # aborts the module graph with a unique violation.
    if [ -n "$SEED_MODULES" ] && [ -r "$SQL_RIBBON" ]; then
        log "[$name] ribbon look: $(basename "$SQL_RIBBON")"
        psql_pg -q -d "$seed" -v seed_label="$SEED_LABEL" -v seed_color="$SEED_COLOR" -f "$SQL_RIBBON"
    fi
    # A seed must not depend on any production file: createdb -T copies the
    # database, not the filestore, so asset bundles are deleted (every clone
    # regenerates them) and business attachments get a blank null pointer instead
    # of a FileNotFoundError 500.
    if [ -r "$SQL_FS" ]; then
        log "[$name] filestore: $(basename "$SQL_FS")"
        psql_pg -q -d "$seed" -f "$SQL_FS"
    fi
    psql_pg -tA -d "$seed" -c "SELECT '${name}: seed = ' || current_database()
        || ' (' || pg_size_pretty(pg_database_size(current_database())) || ')'
        || ', crons_active = ' || (SELECT count(*) FROM ir_cron WHERE active)
        || ', base_url = ' || (SELECT value FROM ir_config_parameter WHERE key = 'web.base.url')"

    if [ "$SEED_FILESTORE" = yes ] && [ -d "${SEED_SOURCE_FILESTORE}/${src}" ]; then
        local db
        for db in $seed $SEED_CLONE_DBS; do
            # --link-dest keeps the nightly copy nearly free; Odoo writes new
            # files instead of rewriting them, so hardlinks are safe here.
            install -d "${SEED_FILESTORE_ROOT}/${db}"
            rsync -a --delete --link-dest="${SEED_SOURCE_FILESTORE}/${src}/" \
                "${SEED_SOURCE_FILESTORE}/${src}/" "${SEED_FILESTORE_ROOT}/${db}/"
            log "[$name] filestore ${db}: $(find "${SEED_FILESTORE_ROOT}/${db}" -type f | wc -l) files"
        done
    fi

    local db
    for db in $SEED_CLONE_DBS; do
        log "[$name] clone ${db} from ${seed}"
        psql_pg -q -c "DROP DATABASE IF EXISTS \"${db}\" WITH (FORCE)"
        psql_pg -q -c "CREATE DATABASE \"${db}\" OWNER \"${role}\" TEMPLATE \"${seed}\""
    done

    ls -1t "${DUMP_DIR}"/"${name}"-*.dump 2>/dev/null | tail -n +$((SEED_RETENTION + 1)) | xargs -r rm -f
}

[ -n "$SEED_TARGETS" ] || die "no SEED_TARGETS in $CONF"
case "${1:-all}" in
    all) for t in $SEED_TARGETS; do refresh_one "$t"; done ;;
    *)   for t in $SEED_TARGETS; do
             case "$(echo "$t" | cut -d'|' -f1)" in
                 "$1") refresh_one "$t" ;;
             esac
         done ;;
esac
log "done"
EOF
chmod 0755 "$HELPER"

echo "--- config (never overwritten)"
if [ ! -e "$CONF" ]; then
    cat > "$CONF" <<'EOF'
# /etc/odoo-seed.conf — nightly neutralized seed of production (odoo-seed-refresh).
# One line per seed: name|source_db|seed_db|role|url|hook_dir
# Create the role once (it owns the seed and every clone made from it):
#   createuser -d seeded_role          # as the postgres user
# hook_dir holds project-specific *.sql applied after the base neutralization.
SEED_TARGETS=""
SEED_MODULES="web_environment_ribbon"
EOF
    chmod 0644 "$CONF"
    echo "  created $CONF — set SEED_TARGETS, then re-run with --run all"
else
    echo "  kept $CONF"
fi

echo "--- daily cron (03:40, after odoo-backup at 03:17)"
cat > /etc/cron.d/odoo-seed <<EOF
40 3 * * * root $HELPER all >> /var/log/odoo-seed.log 2>&1
EOF
chmod 0644 /etc/cron.d/odoo-seed
echo "  /etc/cron.d/odoo-seed installed"

case "${1:-}" in
    --run) shift; bash "$HELPER" "${1:-all}" ;;
    "") echo "done. Next: edit $CONF, then: $HELPER all" ;;
    *) echo "unknown option: $1 (use --run [name|all], or nothing to install)" >&2; exit 2 ;;
esac
