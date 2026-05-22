# Deploying Plane on AWS EC2

This guide covers deploying your custom Plane instance on AWS EC2.

## Quick Start

1. **Launch EC2 Instance**:
   - AMI: Amazon Linux 2023
   - Instance type: m5.large (minimum: 2 vCPU, 8GB RAM)
   - Storage: 30GB+ EBS volume
   - Security group: Allow ports 22, 80, 443

2. **SSH into instance**:

   ```bash
   ssh -i your-key.pem ec2-user@your-instance-ip
   ```

3. **Install git** (Amazon Linux doesn't include it by default):

   ```bash
   sudo yum install -y git
   ```

4. **Clone repositories**:

   ```bash
   # Clone Plane repo
   git clone https://github.com/jribnik/plane.git

   # Clone deployment scripts repo
   git clone https://github.com/jribnik/plane-infra.git
   ```

5. **Run deployment script**:

   ```bash
   cd plane-infra

   # Deploy (use sudo)
   sudo ./deploy-ec2.sh preview

   # Or deploy a specific branch
   sudo ./deploy-ec2.sh kanban-card-cover-images
   ```

6. **Access Plane**:
   - Web: `http://your-instance-ip:3000`
   - API: `http://your-instance-ip:8000`
   - Admin: `http://your-instance-ip:3001/god-mode`

## What the Script Does

The `deploy-ec2.sh` script automates:

1. ✅ System updates and Docker installation
2. ✅ Plane repository cloning to `/opt/plane` and branch checkout
3. ✅ Environment configuration
4. ✅ Docker image building (takes ~10-15 minutes)
5. ✅ Service startup
6. ✅ Optional Nginx reverse proxy setup

**Note:** The deployment scripts are in the `plane-infra` repo, but they will clone and install the actual Plane application to `/opt/plane`.

## Configuration

### Environment Variables

Edit `apps/api/.env` to configure:

**Required**:

- `POSTGRES_PASSWORD` - Database password
- `AWS_ACCESS_KEY_ID` - S3 access key
- `AWS_SECRET_ACCESS_KEY` - S3 secret key
- `AWS_S3_BUCKET_NAME` - S3 bucket for uploads
- `AWS_REGION` - AWS region

**Optional**:

- `WEB_URL` - Your domain (default: localhost)
- `GUNICORN_WORKERS` - API workers (default: 2)
- `FILE_SIZE_LIMIT` - Max upload size in bytes
- `DEBUG` - Set to 0 for production

### Custom Domain

Set the domain before running:

```bash
export PLANE_DOMAIN=plane.yourdomain.com
sudo ./deploy-ec2.sh preview
```

## Managing Services

```bash
cd /opt/plane

# View logs
docker compose logs -f

# View specific service logs
docker compose logs -f api
docker compose logs -f web

# Restart services
docker compose restart

# Stop all services
docker compose down

# Rebuild and restart
docker compose up -d --build

# Check service status
docker compose ps
```

## Updating Deployment

### Using the Upgrade Script (Recommended)

The `upgrade-plane.sh` script handles the entire upgrade process safely:

```bash
# Upgrade to official release
sudo ./upgrade-plane.sh v1.3.1

# Upgrade to latest preview
sudo ./upgrade-plane.sh preview

# Upgrade to custom feature branch
sudo ./upgrade-plane.sh kanban-card-cover-images
```

The script automatically:

- ✅ Creates full backup (database + config)
- ✅ Stops services gracefully
- ✅ Updates code to target version
- ✅ Rebuilds Docker images
- ✅ Runs database migrations
- ✅ Restarts services
- ✅ Performs health checks

### Manual Update

If you prefer manual control:

```bash
cd /opt/plane

# Backup first!
docker compose exec plane-db pg_dump -U plane plane > backup.sql

# Update code
git fetch --all
git checkout your-branch
git pull origin your-branch

# Rebuild and restart
docker compose down
docker compose build --pull
docker compose run --rm api python manage.py migrate
docker compose up -d
```

### Rollback

If something goes wrong:

```bash
# List available backups
ls -lht /opt/plane-backups/

# Rollback to a specific backup
sudo ./rollback-plane.sh /opt/plane-backups/plane-backup-20260521_092000
```

## SSL/TLS Setup (Recommended)

### Using Certbot (Let's Encrypt)

1. **Install Certbot**:

   ```bash
   sudo apt install -y certbot python3-certbot-nginx
   ```

2. **Get certificate**:

   ```bash
   sudo certbot --nginx -d plane.yourdomain.com
   ```

3. **Auto-renewal** (certbot sets this up automatically):
   ```bash
   sudo certbot renew --dry-run
   ```

## Backup & Restore

### Database Backup

```bash
# Backup
docker compose exec plane-db pg_dump -U plane plane > backup.sql

# Restore
docker compose exec -T plane-db psql -U plane plane < backup.sql
```

### Full Backup

```bash
# Backup volumes
docker compose down
sudo tar -czf plane-backup-$(date +%Y%m%d).tar.gz /opt/plane
docker compose up -d
```

## Monitoring

### View Resource Usage

```bash
# Container stats
docker stats

# Disk usage
df -h
docker system df
```

### Health Checks

```bash
# Check if services are responding
curl http://localhost:8000/api/health/
curl http://localhost:3000/
```

## Troubleshooting

### Services won't start

```bash
# Check logs
docker compose logs

# Check specific service
docker compose logs api

# Restart everything
docker compose down
docker compose up -d
```

### Out of disk space

```bash
# Clean up Docker
docker system prune -a --volumes

# Check disk usage
df -h
```

### Performance issues

- Upgrade instance type to t3.large or larger
- Increase `GUNICORN_WORKERS` in `.env`
- Add swap space:
  ```bash
  sudo fallocate -l 4G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
  ```

### Database connection issues

Check PostgreSQL is running:

```bash
docker compose ps plane-db
docker compose logs plane-db
```

## Security Recommendations

1. **Firewall**: Use AWS Security Groups to restrict access
2. **SSL**: Enable HTTPS with Let's Encrypt
3. **Passwords**: Change default passwords in `.env`
4. **Updates**: Regularly update system and Docker images
5. **Backups**: Set up automated daily backups
6. **Monitoring**: Use CloudWatch or similar for alerts

## Cost Optimization

- Use t3.medium for small teams (<10 users)
- Use t3.large for medium teams (10-50 users)
- Consider Reserved Instances for long-term use
- Enable auto-scaling if traffic varies
- Use S3 lifecycle policies for old attachments

## Architecture

```
┌─────────────────┐
│   EC2 Instance  │
│                 │
│  ┌───────────┐  │
│  │   Nginx   │  │ (Optional reverse proxy)
│  │  Port 80  │  │
│  └─────┬─────┘  │
│        │        │
│  ┌─────┴─────┐  │
│  │    Web    │  │ (Next.js app)
│  │  Port 3000│  │
│  └───────────┘  │
│                 │
│  ┌───────────┐  │
│  │    API    │  │ (Django backend)
│  │  Port 8000│  │
│  └───────────┘  │
│                 │
│  ┌───────────┐  │
│  │ PostgreSQL│  │
│  │ Port 5432 │  │
│  └───────────┘  │
│                 │
│  ┌───────────┐  │
│  │   Redis   │  │
│  │ Port 6379 │  │
│  └───────────┘  │
│                 │
│  ┌───────────┐  │
│  │ RabbitMQ  │  │
│  │ Port 5672 │  │
│  └───────────┘  │
└─────────────────┘
```

## Repository Structure

- **Plane Application**: https://github.com/jribnik/plane (installed at `/opt/plane`)
- **Deployment Scripts**: https://github.com/jribnik/plane-infra (this repo)

## Support

- **Issues**: https://github.com/jribnik/plane/issues
- **Upstream Docs**: https://developers.plane.so/
- **Forum**: https://forum.plane.so/
