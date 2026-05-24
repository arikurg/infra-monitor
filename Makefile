# Makefile — run these from the project root
# Usage: make <target>

TERRAFORM_DIR = terraform
ANSIBLE_DIR   = ansible

# ─── Terraform ────────────────────────────────────────────────────────────────

.PHONY: tf-init
tf-init:
	@echo "==> Initialising Terraform (downloads providers)..."
	cd $(TERRAFORM_DIR) && terraform init

.PHONY: tf-plan
tf-plan:
	@echo "==> Planning infrastructure changes..."
	cd $(TERRAFORM_DIR) && terraform plan

.PHONY: tf-apply
tf-apply:
	@echo "==> Applying infrastructure (will create AWS resources)..."
	cd $(TERRAFORM_DIR) && terraform apply
	@echo ""
	@echo "==> Copy the inventory snippet into ansible/inventory.ini:"
	cd $(TERRAFORM_DIR) && terraform output ansible_inventory_snippet

.PHONY: tf-destroy
tf-destroy:
	@echo "==> WARNING: This will DESTROY all AWS resources!"
	cd $(TERRAFORM_DIR) && terraform destroy

# ─── Ansible ──────────────────────────────────────────────────────────────────

.PHONY: ping
ping:
	@echo "==> Pinging all servers to confirm connectivity..."
	cd $(ANSIBLE_DIR) && ansible all -m ping --ask-vault-pass

.PHONY: provision
provision:
	@echo "==> Running full Ansible playbook (all tiers)..."
	cd $(ANSIBLE_DIR) && ansible-playbook playbook.yml --ask-vault-pass

.PHONY: provision-web
provision-web:
	cd $(ANSIBLE_DIR) && ansible-playbook playbook.yml --limit webservers --ask-vault-pass

.PHONY: provision-app
provision-app:
	cd $(ANSIBLE_DIR) && ansible-playbook playbook.yml --limit appservers --ask-vault-pass

.PHONY: provision-db
provision-db:
	cd $(ANSIBLE_DIR) && ansible-playbook playbook.yml --limit dbservers --ask-vault-pass

.PHONY: dry-run
dry-run:
	@echo "==> Ansible dry-run (check mode — no changes made)..."
	cd $(ANSIBLE_DIR) && ansible-playbook playbook.yml --check --ask-vault-pass



# ─── Redeploy ─────────────────────────────────────────────────────────────────

.PHONY: redeploy
redeploy:
	@echo "==> Full redeploy (destroy + recreate + provision)..."
	@chmod +x scripts/redeploy.sh && ./scripts/redeploy.sh

.PHONY: up
up:
	@echo "==> Bringing up infrastructure and provisioning (no destroy)..."
	@chmod +x scripts/redeploy.sh && ./scripts/redeploy.sh --up-only

.PHONY: sync-ips
sync-ips:
	@echo "==> Syncing IPs from AWS into config files..."
	@chmod +x scripts/redeploy.sh && ./scripts/redeploy.sh --ips-only


# ─── Full lifecycle ────────────────────────────────────────────────────────────

.PHONY: deploy
deploy: tf-apply provision
	@echo ""
	@echo "==> Deployment complete!"
	@echo "==> Visit: http://$(shell cd $(TERRAFORM_DIR) && terraform output -raw web_server_public_ip)"

.PHONY: teardown
teardown: tf-destroy
	@echo "==> All resources destroyed."

.PHONY: help
help:
	@echo ""
	@echo "  Terraform targets:"
	@echo "    make tf-init       — download providers"
	@echo "    make tf-plan       — preview changes"
	@echo "    make tf-apply      — create AWS resources"
	@echo "    make tf-destroy    — destroy everything"
	@echo ""
	@echo "  Ansible targets:"
	@echo "    make ping          — test SSH connectivity"
	@echo "    make provision     — run full playbook"
	@echo "    make provision-web — web tier only"
	@echo "    make provision-app — app tier only"
	@echo "    make provision-db  — db tier only"
	@echo "    make dry-run       — check mode, no changes"
	@echo ""
	@echo "  Combined:"
	@echo "    make deploy        — tf-apply + provision"
	@echo "    make teardown      — destroy everything"
	@echo ""
