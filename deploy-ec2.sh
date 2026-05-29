#!/bin/bash

#############################################################################
# Plane EC2 Deployment Script
#
# This script deploys Plane on an AWS EC2 instance using Docker Compose
#
# Prerequisites:
# - Fresh Ubuntu 22.04 LTS or Amazon Linux 2023 EC2 instance
# - Instance type: t3.medium or larger (2+ vCPU, 4GB+ RAM)
# - Security group with ports 80, 443, 22 open
# - Domain name (optional but recommended)
#
# Usage:
#   chmod +x deploy-ec2.sh
#   sudo ./deploy-ec2.sh [branch-name]
#
# Example:
#   sudo ./deploy-ec2.sh preview
#   sudo ./deploy-ec2.sh kanban-card-cover-images
#############################################################################

set -e  # Exit on error

# Configuration
PLANE_REPO="https://github.com/jribnik/plane.git"
BRANCH="${1:-preview}"
INSTALL_DIR="/opt/plane"
DOMAIN="${PLANE_DOMAIN:-localhost}"

# Empty by default so the SDK uses the standard regional endpoint for
# AWS_REGION. GovCloud (and other non-default partitions) are NOT auto-derived
# from the region by django-storages/boto, so set this explicitly there, e.g.
#   export AWS_S3_ENDPOINT_URL=https://s3.us-gov-east-1.amazonaws.com
AWS_S3_ENDPOINT_URL="${AWS_S3_ENDPOINT_URL:-}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

#############################################################################
# Validate required environment variables
#############################################################################
log_info "Validating environment variables..."

REQUIRED_VARS=(
    "AWS_ACCESS_KEY_ID"
    "AWS_SECRET_ACCESS_KEY"
    "AWS_S3_BUCKET_NAME"
    "AWS_REGION"
)

MISSING_VARS=()
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        MISSING_VARS+=("$var")
    fi
done

if [ ${#MISSING_VARS[@]} -gt 0 ]; then
    log_error "Missing required environment variables:"
    for var in "${MISSING_VARS[@]}"; do
        echo "  - $var"
    done
    echo ""
    echo "Please set them before running this script:"
    echo "  export AWS_ACCESS_KEY_ID=your_key"
    echo "  export AWS_SECRET_ACCESS_KEY=your_secret"
    echo "  export AWS_S3_BUCKET_NAME=your_bucket"
    echo "  export AWS_REGION=us-east-1"
    echo ""
    echo "Then run with sudo -E to preserve environment variables:"
    echo "  sudo -E ./deploy-ec2.sh preview"
    exit 1
fi

log_info "✓ All required environment variables are set"
log_info "Starting Plane deployment on EC2..."
log_info "Branch: $BRANCH"
log_info "Domain: $DOMAIN"

#############################################################################
# Step 1: Update system and install dependencies
#############################################################################
log_info "Updating system packages..."

if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="$ID"
else
    log_error "Cannot detect operating system"
    exit 1
fi

if [ "$OS_ID" = "ubuntu" ] || [ "$OS_ID" = "debian" ]; then
    # Ubuntu/Debian
    apt-get update
    apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        git

    # Install Docker
    log_info "Installing Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm get-docker.sh

elif [ "$OS_ID" = "amzn" ] || [ "$OS_ID" = "rhel" ] || [ "$OS_ID" = "centos" ]; then
    # Amazon Linux/RHEL/CentOS
    yum update -y
    yum install -y \
        git \
        docker

    systemctl start docker

    # Install Docker Compose plugin
    log_info "Installing Docker Compose..."
    mkdir -p /usr/local/lib/docker/cli-plugins
    curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

    # Install Docker Buildx plugin
    log_info "Installing Docker Buildx..."
    BUILDX_VERSION=$(curl -s https://api.github.com/repos/docker/buildx/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    curl -SL "https://github.com/docker/buildx/releases/download/v${BUILDX_VERSION}/buildx-v${BUILDX_VERSION}.linux-amd64" -o /usr/local/lib/docker/cli-plugins/docker-buildx
    chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx
else
    log_error "Unsupported operating system: $OS_ID"
    exit 1
fi

# Enable and start Docker
systemctl enable docker
systemctl start docker

log_info "Docker installed successfully"
docker --version
docker compose version

#############################################################################
# Step 2: Clone repository and checkout branch
#############################################################################
log_info "Cloning Plane repository..."

# Remove existing installation if present
if [ -d "$INSTALL_DIR" ]; then
    log_warn "Existing installation found at $INSTALL_DIR"
    read -p "Remove and reinstall? (y/N) " -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Removing existing installation..."
        cd /
        docker compose -f "$INSTALL_DIR/docker-compose.yml" down -v 2>/dev/null || true
        rm -rf "$INSTALL_DIR"
    else
        log_error "Deployment cancelled"
        exit 1
    fi
fi

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

git clone "$PLANE_REPO" .
git checkout "$BRANCH"

log_info "Repository cloned and checked out to branch: $BRANCH"

#############################################################################
# Step 3: Configure environment
#############################################################################
log_info "Configuring environment..."

# Plane's docker-compose.yml needs THREE env files plus an override:
#   - root .env                  : plane-db, plane-mq, and ${...} interpolation
#                                  (proxy port mapping, SITE_ADDRESS) at parse time
#   - apps/api/.env              : api/worker/beat-worker/migrator
#   - apps/live/.env             : the "live" websocket service (upstream compose
#                                  defines no env_file for it, so we add one)
#   - docker-compose.override.yml: wires apps/live/.env into the live service and
#                                  passes SITE_ADDRESS into the proxy (Caddy reads
#                                  it from the container env, not root .env interp)
#
# Several secrets must stay consistent across files (Postgres password shared by
# root .env + apps/api/.env; LIVE_SERVER_SECRET_KEY shared by api + live). To stay
# correct even after an interrupted run that left only some files behind, we
# derive each secret from whichever file already has it, else generate it. Files
# are then written independently so a missing one is always (re)created.

# Read a KEY="value" (or KEY=value) from a file, stripping surrounding quotes.
read_env_value() {
    local key="$1" file="$2"
    [ -f "$file" ] || return 1
    sed -n "s|^${key}=\\(.*\\)|\\1|p" "$file" | head -1 | sed 's|^"\(.*\)"$|\1|'
}

# Derive-or-generate the shared secrets. The `|| true` on each read is load-
# bearing: under `set -e`, a command substitution that exits non-zero (which
# read_env_value does when the file is absent — the normal case on a clean
# install) would otherwise abort the whole script.
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(read_env_value POSTGRES_PASSWORD apps/api/.env \
    || read_env_value POSTGRES_PASSWORD .env || true)}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(openssl rand -hex 16)}"

LIVE_SECRET="$(read_env_value LIVE_SERVER_SECRET_KEY apps/api/.env || true)"
LIVE_SECRET="${LIVE_SECRET:-$(openssl rand -hex 32)}"

SECRET_KEY="$(read_env_value SECRET_KEY apps/api/.env || true)"
SECRET_KEY="${SECRET_KEY:-$(openssl rand -hex 32)}"

#############################################################################
# Root .env (plane-db, plane-mq, proxy)
#############################################################################
if [ ! -f .env ]; then
    cp .env.example .env

    sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=\"$POSTGRES_PASSWORD\"|" .env
    sed -i "s|^AWS_REGION=.*|AWS_REGION=\"$AWS_REGION\"|" .env
    sed -i "s|^AWS_ACCESS_KEY_ID=.*|AWS_ACCESS_KEY_ID=\"$AWS_ACCESS_KEY_ID\"|" .env
    sed -i "s|^AWS_SECRET_ACCESS_KEY=.*|AWS_SECRET_ACCESS_KEY=\"$AWS_SECRET_ACCESS_KEY\"|" .env
    sed -i "s|^AWS_S3_BUCKET_NAME=.*|AWS_S3_BUCKET_NAME=\"$AWS_S3_BUCKET_NAME\"|" .env

    # Use real AWS S3, not the bundled MinIO. Set the endpoint to whatever the
    # operator supplied (empty = default regional endpoint; GovCloud must pass
    # an explicit one), and disable the MinIO container.
    sed -i "s|^USE_MINIO=.*|USE_MINIO=0|" .env
    sed -i "s|^AWS_S3_ENDPOINT_URL=.*|AWS_S3_ENDPOINT_URL=\"$AWS_S3_ENDPOINT_URL\"|" .env

    # Serve the proxy on port 80 of the host.
    sed -i "s|^LISTEN_HTTP_PORT=.*|LISTEN_HTTP_PORT=80|" .env
    sed -i "s|^SITE_ADDRESS=.*|SITE_ADDRESS=:80|" .env

    log_info "Wrote root .env"
else
    log_info "Root .env already exists — leaving it untouched"
fi

#############################################################################
# apps/api/.env (api, worker, beat-worker, migrator)
#############################################################################
if [ ! -f apps/api/.env ]; then
    cp apps/api/.env.example apps/api/.env

    sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=\"$POSTGRES_PASSWORD\"|" apps/api/.env

    sed -i "s|^WEB_URL=.*|WEB_URL=\"http://$DOMAIN\"|" apps/api/.env
    sed -i "s|^ADMIN_BASE_URL=.*|ADMIN_BASE_URL=\"http://$DOMAIN\"|" apps/api/.env
    sed -i "s|^SPACE_BASE_URL=.*|SPACE_BASE_URL=\"http://$DOMAIN\"|" apps/api/.env
    sed -i "s|^APP_BASE_URL=.*|APP_BASE_URL=\"http://$DOMAIN\"|" apps/api/.env
    sed -i "s|^LIVE_BASE_URL=.*|LIVE_BASE_URL=\"http://$DOMAIN\"|" apps/api/.env
    sed -i "s|^LIVE_SERVER_SECRET_KEY=.*|LIVE_SERVER_SECRET_KEY=\"$LIVE_SECRET\"|" apps/api/.env

    sed -i "s|^AWS_REGION=.*|AWS_REGION=\"$AWS_REGION\"|" apps/api/.env
    sed -i "s|^AWS_ACCESS_KEY_ID=.*|AWS_ACCESS_KEY_ID=\"$AWS_ACCESS_KEY_ID\"|" apps/api/.env
    sed -i "s|^AWS_SECRET_ACCESS_KEY=.*|AWS_SECRET_ACCESS_KEY=\"$AWS_SECRET_ACCESS_KEY\"|" apps/api/.env
    sed -i "s|^AWS_S3_BUCKET_NAME=.*|AWS_S3_BUCKET_NAME=\"$AWS_S3_BUCKET_NAME\"|" apps/api/.env

    sed -i "s|^USE_MINIO=.*|USE_MINIO=0|" apps/api/.env
    sed -i "s|^AWS_S3_ENDPOINT_URL=.*|AWS_S3_ENDPOINT_URL=\"$AWS_S3_ENDPOINT_URL\"|" apps/api/.env

    # The api .env.example ships no SECRET_KEY line, so there's nothing for sed
    # to match — append it. Django refuses to start without it.
    echo "SECRET_KEY=\"$SECRET_KEY\"" >> apps/api/.env

    log_info "Wrote apps/api/.env"
else
    log_info "apps/api/.env already exists — leaving it untouched"
    # Even on an existing file, a missing SECRET_KEY is fatal — add it if absent.
    if ! grep -q '^SECRET_KEY=' apps/api/.env; then
        echo "SECRET_KEY=\"$SECRET_KEY\"" >> apps/api/.env
        log_warn "apps/api/.env was missing SECRET_KEY — appended a generated one"
    fi
fi

#############################################################################
# apps/live/.env (live websocket service)
#############################################################################
# Upstream compose defines no env_file for the live service, so it starts with
# no env and its validator hard-exits on missing API_BASE_URL/LIVE_SERVER_SECRET_KEY.
# Internal docker hostnames; PORT=3000 because the proxy upstream is live:3000.
if [ ! -f apps/live/.env ]; then
    cat > apps/live/.env <<EOF
PORT=3000
API_BASE_URL="http://api:8000"
LIVE_BASE_PATH="/live"
LIVE_SERVER_SECRET_KEY="$LIVE_SECRET"
REDIS_HOST="plane-redis"
REDIS_PORT="6379"
REDIS_URL="redis://plane-redis:6379/"
EOF
    log_info "Wrote apps/live/.env"
else
    log_info "apps/live/.env already exists — leaving it untouched"
fi

#############################################################################
# docker-compose.override.yml (wire live env + proxy SITE_ADDRESS)
#############################################################################
# Auto-merged by compose. Adds the env_file the upstream live service lacks, and
# passes SITE_ADDRESS into the proxy container (Caddy reads {$SITE_ADDRESS} from
# its own env; root-.env interpolation does NOT inject vars into containers).
if [ ! -f docker-compose.override.yml ]; then
    cat > docker-compose.override.yml <<'EOF'
services:
  live:
    env_file:
      - ./apps/live/.env
  proxy:
    environment:
      SITE_ADDRESS: ${SITE_ADDRESS:-:80}
EOF
    log_info "Wrote docker-compose.override.yml"
else
    log_info "docker-compose.override.yml already exists — leaving it untouched"
fi

log_info "✓ Environment configured (.env, apps/api/.env, apps/live/.env, override)"
log_info "✓ AWS S3 credentials configured from environment variables"
log_info "✓ Generated PostgreSQL password, Django SECRET_KEY, and live secret"

#############################################################################
# Step 4: Build and start services
#############################################################################
# Building all 9 images at once is disk-hungry; an undersized root volume fails
# ~10 min deep with a cryptic pip "No space left on device". Fail fast instead.
DOCKER_ROOT=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)
AVAIL_GB=$(df -BG --output=avail "$DOCKER_ROOT" 2>/dev/null | tail -1 | tr -dc '0-9')
MIN_GB=20
if [ -n "$AVAIL_GB" ] && [ "$AVAIL_GB" -lt "$MIN_GB" ]; then
    log_error "Only ${AVAIL_GB}GB free on $DOCKER_ROOT; the build needs ~${MIN_GB}GB."
    log_error "Grow the volume (docs recommend 30GB+) and re-run. On AL2023:"
    log_error "  sudo growpart /dev/nvme0n1 1 && sudo xfs_growfs /"
    exit 1
fi
log_info "Disk check OK: ${AVAIL_GB:-?}GB free on $DOCKER_ROOT"

log_info "Building Docker images (this may take 10-15 minutes)..."

# Bake the deployed commit into the web build so the in-app version badge
# shows which commit is live (branches share a package.json version).
APP_GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "")
export APP_GIT_SHA
log_info "Building web with APP_GIT_SHA=${APP_GIT_SHA:-<none>}"

docker compose build

log_info "Starting services..."
docker compose up -d

#############################################################################
# Step 5: Wait for services to be ready
#############################################################################
log_info "Waiting for services to start..."
sleep 30

# Check if services are running
if check_services_healthy; then
    log_info "Services are running!"
else
    log_error "Some services failed to start. Check logs with: docker compose logs"
    exit 1
fi

#############################################################################
# Step 6: Reverse proxy
#############################################################################
# Plane's compose stack ships its own Caddy "proxy" service bound to
# ${LISTEN_HTTP_PORT} (80) on the host, which routes to web/api/admin/space.
# Do NOT add a separate nginx vhost — it would conflict on port 80. If you
# want TLS termination, configure it in Plane's proxy (see DEPLOY_EC2.md).

#############################################################################
# Deployment Complete
#############################################################################
echo ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Plane deployment complete!"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
log_info "Access Plane at: http://$DOMAIN"
echo ""
log_info "Useful commands:"
log_info "  View logs:        cd $INSTALL_DIR && docker compose logs -f"
log_info "  Restart services: cd $INSTALL_DIR && docker compose restart"
log_info "  Stop services:    cd $INSTALL_DIR && docker compose down"
log_info "  Update:           cd $INSTALL_DIR && git pull && docker compose up -d --build"
echo ""
log_info "Service endpoints (all served via the proxy on port 80):"
log_info "  Web App:  http://$DOMAIN/"
log_info "  API:      http://$DOMAIN/api/"
log_info "  Admin:    http://$DOMAIN/god-mode/"
log_info "  Space:    http://$DOMAIN/spaces/"
echo ""
log_warn "Next steps:"
log_warn "  1. Enable HTTPS via the bundled Caddy proxy (set SITE_ADDRESS + CERT_EMAIL in .env)"
log_warn "  2. Set up regular backups of PostgreSQL database"
log_warn "  3. Configure monitoring and logging"
log_warn "  4. Review security group rules"
echo ""
