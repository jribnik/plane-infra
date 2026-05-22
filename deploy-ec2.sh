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
    read -p "Remove and reinstall? (y/N) " -n 1 -r
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

if [ ! -f apps/api/.env ]; then
    cp apps/api/.env.example apps/api/.env

    # Generate secret key
    SECRET_KEY=$(openssl rand -hex 32)

    # Update configuration
    sed -i "s|WEB_URL=\"http://localhost:8000\"|WEB_URL=\"http://$DOMAIN\"|g" apps/api/.env
    sed -i "s|ADMIN_BASE_URL=\"http://localhost:3001\"|ADMIN_BASE_URL=\"http://$DOMAIN\"|g" apps/api/.env
    sed -i "s|SPACE_BASE_URL=\"http://localhost:3002\"|SPACE_BASE_URL=\"http://$DOMAIN\"|g" apps/api/.env
    sed -i "s|APP_BASE_URL=\"http://localhost:3000\"|APP_BASE_URL=\"http://$DOMAIN\"|g" apps/api/.env
    sed -i "s|LIVE_BASE_URL=\"http://localhost:3100\"|LIVE_BASE_URL=\"http://$DOMAIN\"|g" apps/api/.env
    sed -i "s|LIVE_SERVER_SECRET_KEY=\"secret-key\"|LIVE_SERVER_SECRET_KEY=\"$SECRET_KEY\"|g" apps/api/.env
    sed -i "s|DEBUG=0|DEBUG=0|g" apps/api/.env

    # Set AWS credentials from environment variables
    sed -i "s|AWS_ACCESS_KEY_ID=.*|AWS_ACCESS_KEY_ID=\"$AWS_ACCESS_KEY_ID\"|g" apps/api/.env
    sed -i "s|AWS_SECRET_ACCESS_KEY=.*|AWS_SECRET_ACCESS_KEY=\"$AWS_SECRET_ACCESS_KEY\"|g" apps/api/.env
    sed -i "s|AWS_S3_BUCKET_NAME=.*|AWS_S3_BUCKET_NAME=\"$AWS_S3_BUCKET_NAME\"|g" apps/api/.env
    sed -i "s|AWS_REGION=.*|AWS_REGION=\"$AWS_REGION\"|g" apps/api/.env

    log_info "Environment file configured at apps/api/.env"
    log_info "✓ AWS credentials configured from environment variables"
else
    log_info "Using existing .env file"
fi

#############################################################################
# Step 4: Build and start services
#############################################################################
log_info "Building Docker images (this may take 10-15 minutes)..."

docker compose build

log_info "Starting services..."
docker compose up -d

#############################################################################
# Step 5: Wait for services to be ready
#############################################################################
log_info "Waiting for services to start..."
sleep 30

# Check if services are running
if docker compose ps | grep -q "Up"; then
    log_info "Services are running!"
else
    log_error "Some services failed to start. Check logs with: docker compose logs"
    exit 1
fi

#############################################################################
# Step 6: Setup reverse proxy (optional)
#############################################################################
log_info "Checking for reverse proxy setup..."

if command -v nginx &> /dev/null; then
    log_info "Nginx detected. Would you like to configure it for Plane?"
    read -p "Configure Nginx? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        cat > /etc/nginx/sites-available/plane <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    client_max_body_size 10M;
}
EOF
        ln -sf /etc/nginx/sites-available/plane /etc/nginx/sites-enabled/
        nginx -t && systemctl reload nginx
        log_info "Nginx configured successfully"
    fi
fi

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
log_info "Service endpoints:"
log_info "  Web App:  http://$DOMAIN:3000"
log_info "  API:      http://$DOMAIN:8000"
log_info "  Admin:    http://$DOMAIN:3001/god-mode"
log_info "  Space:    http://$DOMAIN:3002/spaces"
echo ""
log_warn "Next steps:"
log_warn "  1. Configure SSL/TLS with Let's Encrypt (certbot)"
log_warn "  2. Set up regular backups of PostgreSQL database"
log_warn "  3. Configure monitoring and logging"
log_warn "  4. Review security group rules"
echo ""
