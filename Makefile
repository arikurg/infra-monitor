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


# ─── Docker + Kubernetes (kind) ─────────────────────────────────────────────────

GHCR_OWNER ?= arikurg
APP_IMAGE   = ghcr.io/$(GHCR_OWNER)/infra-learning-app
WEB_IMAGE   = ghcr.io/$(GHCR_OWNER)/infra-learning-web
TAG        ?= latest
KIND_CLUSTER = infra-learning
# Host platform for kind-load. Multi-arch images pulled from GHCR are stored
# locally as an index missing the other arch's blobs, so `kind load docker-image`
# (which imports --all-platforms) fails. Saving just the host platform to an
# archive sidesteps that.
PLATFORM    ?= linux/$(shell docker version --format '{{.Server.Arch}}')

.PHONY: docker-build
docker-build:
	@echo "==> Building tier images (context = repo root)..."
	docker build -f docker/app/Dockerfile -t $(APP_IMAGE):$(TAG) .
	docker build -f docker/web/Dockerfile -t $(WEB_IMAGE):$(TAG) .

.PHONY: kind-up
kind-up:
	@echo "==> Creating kind cluster + metrics-server (needed for HPA)..."
	kind create cluster --config kind/cluster.yaml
	kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
	kubectl -n kube-system patch deployment metrics-server --type=strategic --patch-file kind/metrics-server.yaml

.PHONY: kind-down
kind-down:
	@echo "==> Deleting kind cluster..."
	kind delete cluster --name $(KIND_CLUSTER)

.PHONY: kind-load
kind-load:
	@echo "==> Loading images into kind ($(PLATFORM) archive, no registry pull needed)..."
	@for img in $(APP_IMAGE):$(TAG) $(WEB_IMAGE):$(TAG); do \
	  tar=$$(mktemp).tar; \
	  docker save --platform $(PLATFORM) -o $$tar $$img; \
	  kind load image-archive $$tar --name $(KIND_CLUSTER); \
	  rm -f $$tar; \
	done

.PHONY: k8s-deploy
k8s-deploy:
	@echo "==> Applying manifests and waiting for rollout..."
	kubectl apply -f k8s/
	kubectl -n infra-learning set image deployment/app app=$(APP_IMAGE):$(TAG)
	kubectl -n infra-learning set image deployment/web web=$(WEB_IMAGE):$(TAG)
	kubectl -n infra-learning rollout status statefulset/db
	kubectl -n infra-learning rollout status deployment/app
	kubectl -n infra-learning rollout status deployment/web
	@echo "==> Visit: http://localhost:8080"

.PHONY: k8s-status
k8s-status:
	kubectl -n infra-learning get pods,svc,hpa,statefulset

.PHONY: k8s-delete
k8s-delete:
	kubectl delete namespace infra-learning

# Full local loop: build → load into kind → deploy. No GHCR needed.
.PHONY: k8s-up
k8s-up: docker-build kind-load k8s-deploy

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
	@echo "  Docker + Kubernetes (kind):"
	@echo "    make docker-build  — build app + web images"
	@echo "    make kind-up       — create kind cluster + metrics-server"
	@echo "    make kind-load     — load built images into kind"
	@echo "    make k8s-deploy    — apply manifests + wait for rollout"
	@echo "    make k8s-up        — build + load + deploy (full local loop)"
	@echo "    make k8s-status    — show pods/svc/hpa"
	@echo "    make k8s-delete    — delete the namespace"
	@echo "    make kind-down     — delete the kind cluster"
	@echo ""
	@echo "  Combined:"
	@echo "    make deploy        — tf-apply + provision"
	@echo "    make teardown      — destroy everything"
	@echo ""
