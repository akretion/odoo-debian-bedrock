#!/usr/bin/env bash
# 60-backup: nightly pg_dump (custom format) + filestore tar, 14-day retention.
#
# The filestore is AUTO-DISCOVERED, covering both options without config:
#   - venv (deb):   /var/lib/odoo/.local/share/Odoo/filestore
#   - docker (dev): /home/app/<project>/data/filestore        (./data/filestore)
#   - docker (prod):/home/app/data/<project>/filestore        (~/data/<proj>/filestore)
# For an exotic layout, edit /usr/local/bin/odoo-backup after install.
#
# Optional off-site: set RCLONE_REMOTE to an rclone remote (e.g. b2:backups/host).
set -euo pipefail
: "${BACKUP_DB:=all}"

install -d /var/backups/odoo

cat > /usr/local/bin/odoo-backup <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
DEST=/var/backups/odoo
TS=$(date +%Y%m%d-%H%M%S)

# databases (all non-template DBs on the host postgres)
DBS=$(su - postgres -c "psql -tAc \"SELECT datname FROM pg_database WHERE datistemplate=false AND datname NOT IN ('postgres')\"" )
for db in $DBS; do
  su - postgres -c "pg_dump -Fc $db" > "$DEST/$TS-$db.dump"
done

# filestore(s) — auto-discovered across the venv + docker conventions
backup_fs() {  # $1 = dir, $2 = slug for the archive name
  [ -d "$1" ] || return 0
  tar -C "$(dirname "$1")" -czf "$DEST/$TS-filestore-$2.tar.gz" "$(basename "$1")" 2>/dev/null || true
}
backup_fs /var/lib/odoo/.local/share/Odoo/filestore deb
for fs in /home/app/*/data/filestore /home/app/data/*/filestore; do
  [ -d "$fs" ] || continue
  slug=$(echo "${fs#/home/app/}" | tr '/' '-')
  backup_fs "$fs" "$slug"
done

[ -n "${RCLONE_REMOTE:-}" ] && rclone copy "$DEST" "$RCLONE_REMOTE" --max-age 24h
find "$DEST" -mtime +14 -delete
EOF
chmod +x /usr/local/bin/odoo-backup

cat > /etc/cron.d/odoo-backup <<EOF
17 3 * * * root /usr/local/bin/odoo-backup >> /var/log/odoo-backup.log 2>&1
EOF
