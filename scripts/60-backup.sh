#!/usr/bin/env bash
# 60-backup: nightly pg_dump (custom format) + filestore tar for the databases
# you choose, with an N-day retention. Deliberately simple: a safety net that
# works on any host, not a backup platform (premium setups get gobackup/barman).
#
# WHICH DATABASES — /etc/odoo-backup.conf, BACKUP_DBS:
#   BACKUP_DBS="all"                every non-template DB except 'postgres'
#   BACKUP_DBS="prod_db other_db"   only these
# The config is created on first install and NEVER overwritten afterwards, so
# re-running this script only refreshes the helper + the cron entry. Pass
# BACKUP_DBS=... on the FIRST run to seed the config with your list.
#
# The filestore is AUTO-DISCOVERED, covering both options without config:
#   - venv (deb):   /var/lib/odoo/.local/share/Odoo/filestore
#   - venv (adhoc): /home/<user>/.local/share/Odoo/filestore    (plain install)
#   - docker (dev): /home/app/<project>/data/filestore        (./data/filestore)
#   - docker (prod):/home/app/data/<project>/filestore        (~/data/<proj>/filestore)
# With an explicit BACKUP_DBS list only the sub-directories named after those
# databases are archived; for an exotic layout use EXTRA_FILESTORE_DIRS.
#
# Optional off-site: set RCLONE_REMOTE to an rclone remote (e.g. b2:backups/host).
set -euo pipefail

install -d -m 0700 /var/backups/odoo

cat > /usr/local/bin/odoo-backup <<'EOF'
#!/usr/bin/env bash
# Installed by odoo-debian-bedrock (scripts/60-backup.sh).
# CONFIGURE IN /etc/odoo-backup.conf — this file is rewritten on bedrock update.
set -euo pipefail

CONF=/etc/odoo-backup.conf
DEST=/var/backups/odoo

# defaults; every one of them can be overridden in $CONF
BACKUP_DBS=all
BACKUP_FILESTORE=yes
RETENTION_DAYS=7
RCLONE_REMOTE=
EXTRA_FILESTORE_DIRS=
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"

TS=$(date +%Y%m%d-%H%M%S)
log() { echo "$(date '+%F %T') $*"; }

# --- which databases ------------------------------------------------------
DBS=()
if [ "$BACKUP_DBS" = all ]; then
  while IFS= read -r db; do
    [ -n "$db" ] && DBS+=("$db")
  done < <(su - postgres -c "psql -tAc \"SELECT datname FROM pg_database WHERE datistemplate=false AND datname <> 'postgres' ORDER BY datname\"")
else
  read -r -a WANTED <<< "$BACKUP_DBS"
  for db in "${WANTED[@]}"; do
    if su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='$db'\"" | grep -q 1; then
      DBS+=("$db")
    else
      log "WARNING: database '$db' listed in $CONF does not exist — skipped"
    fi
  done
fi
if [ "${#DBS[@]}" -eq 0 ]; then
  log "ERROR: no database selected for backup (BACKUP_DBS='$BACKUP_DBS' in $CONF)"
  exit 1
fi
log "backup start: databases ${DBS[*]} -> $DEST"

# --- databases ------------------------------------------------------------
# Globals (roles/passwords) are tiny and make a bare restore possible.
su - postgres -c "pg_dumpall --globals-only" | gzip -c > "$DEST/$TS-globals.sql.gz"

for db in "${DBS[@]}"; do
  log "pg_dump $db"
  tmp="$DEST/.$TS-$db.dump.part"
  su - postgres -c "pg_dump -Fc -d $db" > "$tmp"
  if [ ! -s "$tmp" ]; then
    log "ERROR: dump of $db is empty — aborted"
    rm -f "$tmp"
    exit 1
  fi
  mv "$tmp" "$DEST/$TS-$db.dump"
done

# --- filestore(s) ---------------------------------------------------------
backup_fs() {  # $1 = filestore dir, $2 = slug for the archive name
  [ -d "$1" ] || return 0
  log "filestore $1"
  tar -C "$(dirname "$1")" -czf "$DEST/$TS-filestore-$2.tar.gz" "$(basename "$1")" 2>/dev/null || true
}

if [ "$BACKUP_FILESTORE" = yes ]; then
  ROOTS=(/var/lib/odoo/.local/share/Odoo/filestore)
  # A PLAIN venv install (no deb, no docker) keeps its data dir under the user's
  # home: /home/<user>/.local/share/Odoo/filestore. It is the layout an adhoc
  # venv production has before it is standardised, and missing it means the
  # nightly backup silently contains dumps and NO attachments.
  for fs in /home/*/.local/share/Odoo/filestore; do
    [ -d "$fs" ] && ROOTS+=("$fs")
  done
  for fs in /home/app/*/data/filestore /home/app/data/*/filestore; do
    [ -d "$fs" ] && ROOTS+=("$fs")
  done
  for root in "${ROOTS[@]}"; do
    [ -d "$root" ] || continue
    if [ "$BACKUP_DBS" = all ]; then
      backup_fs "$root" "$(echo "${root#/}" | tr '/' '-')"
    else
      for db in "${DBS[@]}"; do
        [ -d "$root/$db" ] && backup_fs "$root/$db" "$db"
      done
    fi
  done
  read -r -a EXTRA <<< "$EXTRA_FILESTORE_DIRS"
  for d in "${EXTRA[@]}"; do
    backup_fs "$d" "$(basename "$d")"
  done
fi

# --- off-site + retention -------------------------------------------------
if [ -n "$RCLONE_REMOTE" ] && command -v rclone >/dev/null 2>&1; then
  log "rclone copy -> $RCLONE_REMOTE"
  rclone copy "$DEST" "$RCLONE_REMOTE" --max-age 24h
fi
find "$DEST" -maxdepth 1 -type f -mtime +"$RETENTION_DAYS" -delete
log "backup done: $(find "$DEST" -maxdepth 1 -type f | wc -l) archives in $DEST ($(du -sh "$DEST" | cut -f1))"
EOF
chmod 0755 /usr/local/bin/odoo-backup

# Operator config: seeded once, never clobbered by a bedrock update.
CONF=/etc/odoo-backup.conf
if [ ! -e "$CONF" ]; then
  cat > "$CONF" <<EOF
# odoo-debian-bedrock backup config — read by /usr/local/bin/odoo-backup.
# The daily cron is /etc/cron.d/odoo-backup (03:17).

# Databases to dump, space-separated, or 'all' (every non-template DB except
# 'postgres'). List the real business databases only: hosts accumulate old
# copies and CI databases, and dumping everything usually does not fit in the
# disk or in the night.
BACKUP_DBS="${BACKUP_DBS:-all}"

# Also archive the Odoo filestore(s) (attachments). Usually much larger than
# the dumps — measure one night before raising RETENTION_DAYS.
BACKUP_FILESTORE="${BACKUP_FILESTORE:-yes}"

# Delete archives older than this many days.
RETENTION_DAYS="${RETENTION_DAYS:-7}"

# Off-site copy (needs rclone installed): e.g. b2:my-bucket/odoo
RCLONE_REMOTE="${RCLONE_REMOTE:-}"

# Filestore directories that auto-discovery misses (space-separated).
EXTRA_FILESTORE_DIRS="${EXTRA_FILESTORE_DIRS:-}"
EOF
  chmod 0644 "$CONF"
  echo "created $CONF"
else
  echo "keeping existing $CONF (edit it to change the database list)"
fi

cat > /etc/cron.d/odoo-backup <<'EOF'
17 3 * * * root /usr/local/bin/odoo-backup >> /var/log/odoo-backup.log 2>&1
EOF
chmod 0644 /etc/cron.d/odoo-backup
