#!/usr/bin/env bash
# 60-backup: nightly pg_dump (custom format) + filestore tar, 14-day retention.
#
# FILESTORE_DIR = Odoo's filestore root on the host (per-db subdirs under it):
#   layer 1 (deb):    /var/lib/odoo/.local/share/Odoo/filestore   (default)
#   layer 2 (docker): the host-mounted volume, e.g. /home/app/soleio/data/filestore
#                     (mount the project's filestore volume there, then set this)
#
# Optional off-site: set RCLONE_REMOTE to an rclone remote (e.g. b2:backups/host).
set -euo pipefail
: "${BACKUP_DB:=all}"
: "${FILESTORE_DIR:=/var/lib/odoo/.local/share/Odoo/filestore}"

FILESTORE_PARENT=$(dirname "$FILESTORE_DIR")
FILESTORE_BASE=$(basename "$FILESTORE_DIR")

install -d /var/backups/odoo

cat > /usr/local/bin/odoo-backup <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
DEST=/var/backups/odoo
TS=$(date +%Y%m%d-%H%M%S)
DBS=$(su - postgres -c "psql -tAc \"SELECT datname FROM pg_database WHERE datistemplate=false AND datname NOT IN ('postgres')\"" )
for db in $DBS; do
  su - postgres -c "pg_dump -Fc $db" > "$DEST/$TS-$db.dump"
done
if [ -d "@FILESTORE_DIR@" ]; then
  tar -C "@FILESTORE_PARENT@" -czf "$DEST/$TS-filestore.tar.gz" "@FILESTORE_BASE@" 2>/dev/null || true
fi
[ -n "${RCLONE_REMOTE:-}" ] && rclone copy "$DEST" "$RCLONE_REMOTE" --max-age 24h
find "$DEST" -mtime +14 -delete
EOF
sed -i \
  -e "s|@FILESTORE_DIR@|$FILESTORE_DIR|g" \
  -e "s|@FILESTORE_PARENT@|$FILESTORE_PARENT|g" \
  -e "s|@FILESTORE_BASE@|$FILESTORE_BASE|g" \
  /usr/local/bin/odoo-backup
chmod +x /usr/local/bin/odoo-backup

cat > /etc/cron.d/odoo-backup <<EOF
17 3 * * * root /usr/local/bin/odoo-backup >> /var/log/odoo-backup.log 2>&1
EOF
