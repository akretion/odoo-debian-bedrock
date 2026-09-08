#!/usr/bin/env bash
# 60-backup: nightly pg_dump (custom format) + filestore tar, 14-day retention.
# Optional off-site: set RCLONE_REMOTE to an rclone remote (e.g. b2:backups/host).
set -euo pipefail
: "${BACKUP_DB:=all}"

install -d -o odoo -g odoo /var/backups/odoo

cat > /usr/local/bin/odoo-backup <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
DEST=/var/backups/odoo
TS=$(date +%Y%m%d-%H%M%S)
DBS=$(su - postgres -c "psql -tAc \"SELECT datname FROM pg_database WHERE datistemplate=false AND datname NOT IN ('postgres')\"")
for db in $DBS; do
  su - postgres -c "pg_dump -Fc $db" > "$DEST/$TS-$db.dump"
done
tar -C /var/lib/odoo -czf "$DEST/$TS-filestore.tar.gz" .local/share/Odoo/filestore 2>/dev/null || true
[ -n "${RCLONE_REMOTE:-}" ] && rclone copy "$DEST" "$RCLONE_REMOTE" --max-age 24h
find "$DEST" -mtime +14 -delete
EOF
chmod +x /usr/local/bin/odoo-backup

cat > /etc/cron.d/odoo-backup <<EOF
17 3 * * * root /usr/local/bin/odoo-backup >> /var/log/odoo/backup.log 2>&1
EOF
