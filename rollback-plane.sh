#!/bin/bash

#############################################################################
# Plane Rollback Script
#
# Quickly rollback to a previous backup
#
# Usage:
#   sudo ./rollback-plane.sh [backup-directory]
#
# Example:
#   sudo ./rollback-plane.sh /opt/plane-backups/plane-backup-20260521_092000
#############################################################################

set -e

BACKUP_DIR="${1}"
INSTALL_DIR="/opt/plane"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    log_error "Please run as root (use sudo)"
    exit 1
fi

if [ -z "$BACKUP_DIR" ]; then
    log_error "Usage: $0 <backup-directory>"
    echo ""
    echo "Available backups:"
    ls -lht /opt/plane-backups/ 2>/dev/null | grep "^d" | head -10
    exit 1
fi

if [ ! -d "$BACKUP_DIR" ]; then
    log_error "Backup directory not found: $BACKUP_DIR"
    exit 1
fi

log_info "Rolling back to: $BACKUP_DIR"
echo ""
log_warn "This will:"
log_warn "  1. Stop current services"
log_warn "  2. Restore database from backup"
log_warn "  3. Restore configuration files"
log_warn "  4. Restart services"
echo ""
read -p "Continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
fi

cd "$INSTALL_DIR"

log_info "Stopping services..."
docker compose down

log_info "Restoring configuration..."
[ -f "$BACKUP_DIR/.env" ] && cp "$BACKUP_DIR/.env" "$INSTALL_DIR/"
[ -f "$BACKUP_DIR/api.env" ] && cp "$BACKUP_DIR/api.env" "$INSTALL_DIR/apps/api/.env"

log_info "Starting database..."
docker compose up -d plane-db
sleep 10

log_info "Restoring database..."
if [ -f "$BACKUP_DIR/database.sql" ]; then
    docker compose exec -T plane-db psql -U plane plane < "$BACKUP_DIR/database.sql"
    log_info "Database restored"
else
    log_warn "No database backup found"
fi

log_info "Starting all services..."
docker compose up -d

log_info "Rollback complete!"
