#!/bin/bash

#############################################################################
# Plane Upgrade Script
#
# Upgrades a running Plane instance to a new version (official or custom branch)
#
# Prerequisites:
# - Existing Plane installation (typically at /opt/plane or ~/plane-app)
# - Docker and docker-compose installed
# - Root/sudo access
#
# Usage:
#   chmod +x upgrade-plane.sh
#   sudo ./upgrade-plane.sh [version|branch]
#
# Examples:
#   sudo ./upgrade-plane.sh v1.3.1                    # Official release
#   sudo ./upgrade-plane.sh preview                    # Latest preview branch
#   sudo ./upgrade-plane.sh kanban-card-cover-images  # Custom feature branch
#
#############################################################################

set -e  # Exit on error

# Configuration
DEFAULT_INSTALL_DIR="/opt/plane"
BACKUP_DIR="/opt/plane-backups"
TARGET_VERSION="${1:-preview}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}▶${NC} $1"
}

# Verify the compose stack is healthy. Returns non-zero if any long-running
# service is not "running", treating a clean exit of one-shot jobs (the
# "migrator" service, which runs migrations then exits 0) as success. This is
# more reliable than grepping for "Up", whose wording varies across Compose
# versions.
check_services_healthy() {
    local bad
    bad=$(docker compose ps -a --format '{{.Service}}|{{.State}}|{{.ExitCode}}' 2>/dev/null \
        | awk -F'|' '
            $1 == "migrator" { if ($3 != 0) print $0; next }   # one-shot: only fail on nonzero exit
            $2 != "running"  { print $0 }
        ')
    if [ -n "$bad" ]; then
        log_error "The following services are not healthy:"
        echo "$bad" | awk -F'|' '{ printf "  - %s (%s, exit=%s)\n", $1, $2, $3 }'
        return 1
    fi
    return 0
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "Please run as root (use sudo)"
    exit 1
fi

# Find Plane installation
find_plane_installation() {
    if [ -d "$DEFAULT_INSTALL_DIR" ]; then
        echo "$DEFAULT_INSTALL_DIR"
    elif [ -d "$HOME/plane-app" ]; then
        echo "$HOME/plane-app"
    elif [ -d "/var/lib/plane" ]; then
        echo "/var/lib/plane"
    else
        log_error "Could not find Plane installation"
        log_error "Checked: $DEFAULT_INSTALL_DIR, $HOME/plane-app, /var/lib/plane"
        exit 1
    fi
}

INSTALL_DIR=$(find_plane_installation)
log_info "Found Plane installation at: $INSTALL_DIR"

#############################################################################
# Pre-upgrade checks
#############################################################################
log_step "Running pre-upgrade checks..."

# Check if docker-compose file exists
if [ ! -f "$INSTALL_DIR/docker-compose.yml" ] && [ ! -f "$INSTALL_DIR/docker-compose.yaml" ]; then
    log_error "docker-compose file not found in $INSTALL_DIR"
    exit 1
fi

# Find the docker-compose file
if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
    COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
else
    COMPOSE_FILE="$INSTALL_DIR/docker-compose.yaml"
fi

# Check if any services are currently running (pre-flight warning only)
cd "$INSTALL_DIR"
if [ -z "$(docker compose ps --status running -q 2>/dev/null)" ]; then
    log_warn "No running containers found. Services may be stopped."
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_error "Upgrade cancelled"
        exit 1
    fi
fi

#############################################################################
# Create backup
#############################################################################
log_step "Creating backup..."

BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_PATH="$BACKUP_DIR/plane-backup-$BACKUP_TIMESTAMP"
mkdir -p "$BACKUP_PATH"

# Backup database
log_info "Backing up database..."
docker compose exec -T plane-db pg_dump -U plane plane > "$BACKUP_PATH/database.sql" 2>/dev/null || {
    log_warn "Database backup failed or no database running"
}

# Backup environment files
log_info "Backing up configuration..."
cp -r "$INSTALL_DIR/.env" "$BACKUP_PATH/" 2>/dev/null || true
cp -r "$INSTALL_DIR/plane.env" "$BACKUP_PATH/" 2>/dev/null || true
cp -r "$INSTALL_DIR/apps/api/.env" "$BACKUP_PATH/api.env" 2>/dev/null || true

# Backup docker-compose
cp "$COMPOSE_FILE" "$BACKUP_PATH/"

log_info "Backup saved to: $BACKUP_PATH"

#############################################################################
# Get current version
#############################################################################
CURRENT_BRANCH=$(git -C "$INSTALL_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
CURRENT_COMMIT=$(git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
log_info "Current: $CURRENT_BRANCH @ $CURRENT_COMMIT"
log_info "Target: $TARGET_VERSION"

echo ""
read -p "Proceed with upgrade? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_error "Upgrade cancelled"
    exit 1
fi

#############################################################################
# Stop services
#############################################################################
log_step "Stopping services..."
docker compose down

#############################################################################
# Update code
#############################################################################
log_step "Updating code to $TARGET_VERSION..."

# Check if this is a git repo
if [ -d "$INSTALL_DIR/.git" ]; then
    cd "$INSTALL_DIR"

    # Stash any local changes
    git stash push -m "Pre-upgrade stash $BACKUP_TIMESTAMP" || true

    # Fetch latest
    git fetch --all --tags

    # Resolve the target, in priority order: version tag (v-prefixed), then a
    # local ref (tag/branch/commit), then a remote-only branch. The last case
    # is the common one: a branch like "production-release" that exists on the
    # remote but has never been checked out on this box, so it has no local
    # ref and `git rev-parse production-release` would fail. We check
    # origin/<name> and let `git checkout <name>` create the local tracking
    # branch (git's DWIM behavior).
    if git rev-parse --verify "refs/tags/v$TARGET_VERSION" >/dev/null 2>&1; then
        # It's a version tag (with v prefix)
        git checkout "v$TARGET_VERSION"
        log_info "Checked out tag: v$TARGET_VERSION"
    elif git rev-parse --verify "$TARGET_VERSION" >/dev/null 2>&1; then
        # It's a local tag, branch, or commit
        git checkout "$TARGET_VERSION"

        # If it's a local branch, pull latest
        if git show-ref --verify --quiet "refs/heads/$TARGET_VERSION"; then
            git pull origin "$TARGET_VERSION"
            log_info "Pulled latest from branch: $TARGET_VERSION"
        else
            log_info "Checked out: $TARGET_VERSION"
        fi
    elif git rev-parse --verify "refs/remotes/origin/$TARGET_VERSION" >/dev/null 2>&1; then
        # Remote-only branch: checkout creates a local branch tracking origin,
        # which already points at the just-fetched tip (no pull needed).
        git checkout "$TARGET_VERSION"
        log_info "Checked out remote branch: origin/$TARGET_VERSION"
    else
        log_error "Invalid version/branch: $TARGET_VERSION"
        log_error "Restoring from backup..."
        git checkout "$CURRENT_BRANCH"
        exit 1
    fi
else
    log_error "$INSTALL_DIR is not a git repository"
    log_error "Cannot update via git. Please update manually or reinstall."
    exit 1
fi

NEW_COMMIT=$(git rev-parse --short HEAD)
log_info "Updated to: $TARGET_VERSION @ $NEW_COMMIT"

#############################################################################
# Rebuild images
#############################################################################
log_step "Rebuilding Docker images (this may take 10-15 minutes)..."

docker compose build --pull

#############################################################################
# Run migrations
#############################################################################
log_step "Running database migrations..."

# Start database first
docker compose up -d plane-db plane-redis

# Wait for database
log_info "Waiting for database to be ready..."
sleep 10

# Run migrations
docker compose run --rm api python manage.py migrate || {
    log_error "Migration failed!"
    log_error "Check logs with: docker compose logs api"
    exit 1
}

#############################################################################
# Start services
#############################################################################
log_step "Starting all services..."
docker compose up -d

#############################################################################
# Health check
#############################################################################
log_step "Running health checks..."
sleep 20

if check_services_healthy; then
    log_info "Services are running"
else
    log_error "Some services failed to start"
    log_error "Check logs with: docker compose logs"
    exit 1
fi

# Test the app through the proxy. The api container does not publish a host
# port; everything is reachable via the Caddy proxy on ${LISTEN_HTTP_PORT}.
HTTP_PORT="${LISTEN_HTTP_PORT:-80}"
log_info "Testing app endpoint (http://localhost:$HTTP_PORT/)..."
for i in {1..10}; do
    if curl -sf "http://localhost:$HTTP_PORT/" >/dev/null; then
        log_info "App is responding"
        break
    fi
    if [ "$i" -eq 10 ]; then
        log_warn "App not responding after 30 seconds"
        log_warn "This may be normal during first startup. Check logs if issues persist."
    fi
    sleep 3
done

#############################################################################
# Upgrade Complete
#############################################################################
echo ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Upgrade complete!"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
log_info "Previous: $CURRENT_BRANCH @ $CURRENT_COMMIT"
log_info "Current:  $TARGET_VERSION @ $NEW_COMMIT"
echo ""
log_info "Backup saved at: $BACKUP_PATH"
echo ""
log_info "Useful commands:"
log_info "  View logs:        cd $INSTALL_DIR && docker compose logs -f"
log_info "  Restart services: cd $INSTALL_DIR && docker compose restart"
log_info "  Rollback:         sudo $0 $CURRENT_BRANCH"
echo ""
log_warn "If you encounter issues:"
log_warn "  1. Check logs: docker compose logs"
log_warn "  2. Restore database: docker compose exec -T plane-db psql -U plane plane < $BACKUP_PATH/database.sql"
log_warn "  3. Rollback version: sudo $0 $CURRENT_BRANCH"
echo ""

#############################################################################
# Cleanup old backups (keep last 5)
#############################################################################
log_info "Cleaning up old backups (keeping last 5)..."
cd "$BACKUP_DIR"
ls -t | tail -n +6 | xargs -r rm -rf
