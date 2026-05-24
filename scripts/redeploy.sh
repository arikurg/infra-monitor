#!/usr/bin/env bash
# scripts/redeploy.sh
#
# Full automated redeploy — provisions infrastructure, reads the new IPs,
# updates all config files, and runs Ansible to configure everything.
#
# Usage:
#   ./scripts/redeploy.sh            # full redeploy (destroy + recreate)
#   ./scripts/redeploy.sh --up-only  # just update configs + provision (no destroy)
#   ./scripts/redeploy.sh --ips-only # just update config files from current IPs

set -euo pipefail

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}==>${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn()    { echo -e "${YELLOW}!${NC} $1"; }
error()   { echo -e "${RED}✗${NC} $1"; exit 1; }

# ─── Paths ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_DIR/terraform"
ANSIBLE_DIR="$PROJECT_DIR/ansible"

INVENTORY="$ANSIBLE_DIR/inventory.ini"
NGINX_CONF="$ANSIBLE_DIR/roles/webserver/templates/nginx.conf.j2"
APP_VARS="$ANSIBLE_DIR/group_vars/appservers/vars.yml"

# ─── Flags ────────────────────────────────────────────────────────────────────
FULL_REDEPLOY=true
RUN_ANSIBLE=true

for arg in "$@"; do
  case $arg in
    --up-only)  FULL_REDEPLOY=false ;;
    --ips-only) FULL_REDEPLOY=false; RUN_ANSIBLE=false ;;
  esac
done

# ─── Checks ───────────────────────────────────────────────────────────────────
command -v terraform >/dev/null 2>&1 || error "terraform not found — install it first"
command -v ansible-playbook >/dev/null 2>&1 || error "ansible-playbook not found — pip install ansible"
command -v aws >/dev/null 2>&1 || error "aws CLI not found — install it first"

[[ -f "$TERRAFORM_DIR/terraform.tfvars" ]] || \
  error "terraform.tfvars not found — copy terraform.tfvars.example and fill it in"

# ─── Step 1: Update your IP ───────────────────────────────────────────────────
info "Detecting your current public IP..."
YOUR_IP=$(curl -s -4 ifconfig.me)
[[ -n "$YOUR_IP" ]] || error "Could not detect your public IP"
success "Your IP: $YOUR_IP"

# Update terraform.tfvars with current IP
sed -i.bak "s|your_ip.*=.*|your_ip = \"${YOUR_IP}/32\"|" "$TERRAFORM_DIR/terraform.tfvars"
success "Updated terraform.tfvars with your current IP"

# ─── Step 2: Terraform ────────────────────────────────────────────────────────
cd "$TERRAFORM_DIR"

if [[ "$FULL_REDEPLOY" == true ]]; then
  info "Destroying existing infrastructure..."
  terraform destroy -auto-approve
  success "Infrastructure destroyed"
fi

info "Provisioning infrastructure with Terraform..."
terraform init -upgrade -input=false > /dev/null
terraform apply -auto-approve
success "Infrastructure provisioned"

# ─── Step 3: Read new IPs ─────────────────────────────────────────────────────
info "Reading new IP addresses..."

# Get Elastic IPs by name tag
WEB_IP=$(aws ec2 describe-addresses \
  --filters "Name=tag:Name,Values=infra-learning-web-eip" \
  --query 'Addresses[0].PublicIp' --output text)

APP_IP=$(aws ec2 describe-addresses \
  --filters "Name=tag:Name,Values=infra-learning-app-eip" \
  --query 'Addresses[0].PublicIp' --output text)

DB_IP=$(aws ec2 describe-addresses \
  --filters "Name=tag:Name,Values=infra-learning-db-eip" \
  --query 'Addresses[0].PublicIp' --output text)

# Get DB private IP for Node.js connection
DB_PRIVATE_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=infra-learning-db" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)

APP_PRIVATE_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=infra-learning-app" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)

[[ "$WEB_IP" == "None" || -z "$WEB_IP" ]] && error "Could not find web EIP — did Terraform apply succeed?"
[[ "$APP_IP" == "None" || -z "$APP_IP" ]] && error "Could not find app EIP"
[[ "$DB_IP"  == "None" || -z "$DB_IP"  ]] && error "Could not find db EIP"

echo ""
echo -e "  Web:  ${GREEN}$WEB_IP${NC}"
echo -e "  App:  ${GREEN}$APP_IP${NC} (private: $APP_PRIVATE_IP)"
echo -e "  DB:   ${GREEN}$DB_IP${NC}  (private: $DB_PRIVATE_IP)"
echo ""

# ─── Step 4: Update ansible/inventory.ini ─────────────────────────────────────
info "Updating ansible/inventory.ini..."
cat > "$INVENTORY" << EOF
[webservers]
$WEB_IP ansible_user=ec2-user

[appservers]
$APP_PRIVATE_IP ansible_user=ec2-user

[dbservers]
$DB_PRIVATE_IP ansible_user=ec2-user ansible_host=$DB_IP

[all:children]
webservers
appservers
dbservers

[all:vars]
ansible_ssh_private_key_file=~/.ssh/infra-learning.pem
ansible_ssh_common_args='-o StrictHostKeyChecking=no'

[appservers:vars]
ansible_ssh_common_args='-o StrictHostKeyChecking=no -A -o ProxyJump=ec2-user@$WEB_IP'

[dbservers:vars]
ansible_ssh_common_args='-o StrictHostKeyChecking=no -A -o ProxyJump=ec2-user@$WEB_IP,ec2-user@$APP_PRIVATE_IP'
EOF
success "Updated inventory.ini"

# ─── Step 5: Update nginx.conf.j2 ─────────────────────────────────────────────
info "Updating nginx.conf.j2 proxy_pass..."
sed -i.bak "s|proxy_pass.*http://.*:3000;|proxy_pass         http://$APP_PRIVATE_IP:3000;|" "$NGINX_CONF"
success "Updated nginx.conf.j2"

# ─── Step 6: Update group_vars/appservers/vars.yml ────────────────────────────
info "Updating appservers vars..."
mkdir -p "$ANSIBLE_DIR/group_vars/appservers"
cat > "$APP_VARS" << EOF
---
db_private_ip: "$DB_PRIVATE_IP"
EOF
success "Updated group_vars/appservers/vars.yml"

# ─── Step 7: Add SSH key to agent ─────────────────────────────────────────────
info "Adding SSH key to agent..."
ssh-add ~/.ssh/infra-learning.pem 2>/dev/null || warn "Could not add key to agent — may already be added"
success "SSH key ready"

# ─── Step 8: Run Ansible ──────────────────────────────────────────────────────
if [[ "$RUN_ANSIBLE" == true ]]; then
  info "Waiting 20s for instances to finish booting..."
  sleep 20

  info "Running Ansible playbook..."
  cd "$ANSIBLE_DIR"
  ansible-playbook playbook.yml --ask-vault-pass

  success "Ansible provisioning complete"
fi

# ─── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Deployment complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Status page: ${BLUE}http://$WEB_IP${NC}"
echo -e "  API:         ${BLUE}http://$WEB_IP/api/status${NC}"
echo ""
echo -e "  ${YELLOW}Note:${NC} Reset the PostgreSQL password if this was a fresh deploy:"
echo -e "  ssh -i ~/.ssh/infra-learning.pem ec2-user@$DB_IP \\"
echo -e "    \"sudo -u postgres psql -c \\\"ALTER USER appuser WITH PASSWORD 'YourPassword!';\\\"\""
echo ""
