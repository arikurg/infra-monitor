# infra-learning

A 3-tier web application (Nginx → Node.js → PostgreSQL) you can deploy **two
ways**, built to learn infrastructure skills for DevOps internships:

- **On AWS** with **Terraform** (provision) and **Ansible** (configure) — the
  cloud path, below.
- **Locally on Kubernetes** with **Docker** + **kind**, plus a **GitHub Actions**
  CI/CD pipeline — see [Containers + Kubernetes](#containers--kubernetes-local-kind).

```
AWS:   Internet → Nginx (web) → Node.js (app) → PostgreSQL (db)
                  public subnet   private subnet   db subnet

kind:  localhost → web Deployment → app Deployment (+HPA) → db StatefulSet
                   (NodePort)        (rolling updates)        (PVC)
```

## What you'll learn

- **Terraform**: VPCs, subnets, security groups, EC2 instances, state management
- **Ansible**: roles, handlers, Jinja2 templates, vault (secrets), idempotent tasks
- **Networking**: public vs private subnets, route tables, internet gateways
- **Security**: least-privilege security groups, SSH bastion pattern, secrets management
- **Linux**: systemd services, firewalld, PostgreSQL setup
- **Docker**: multi-tier images, layer caching, env-driven config, non-root containers
- **Kubernetes**: Deployments, StatefulSets, Services, ConfigMaps/Secrets, probes,
  rolling updates, Horizontal Pod Autoscaling (on a local kind cluster)
- **CI/CD**: GitHub Actions building/pushing images to GHCR and deploying via a
  self-hosted runner

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Terraform | ≥ 1.5 | `brew install terraform` |
| Ansible | ≥ 2.14 | `pip install ansible` |
| AWS CLI | ≥ 2 | `brew install awscli` |
| AWS account | free tier | [aws.amazon.com](https://aws.amazon.com) |

**Configure AWS credentials:**
```bash
aws configure
# Enter: Access Key ID, Secret Access Key, region (us-east-1), output (json)
```

---

## Step-by-step setup

### 1. Create an SSH key pair in AWS
```bash
aws ec2 create-key-pair \
  --key-name infra-learning \
  --query 'KeyMaterial' \
  --output text > ~/.ssh/infra-learning.pem

chmod 400 ~/.ssh/infra-learning.pem
```

### 2. Create your Terraform variables file
```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` — set your public IP:
```bash
curl ifconfig.me   # copy this output
```

### 3. Provision infrastructure with Terraform
```bash
make tf-init    # download providers (~30s)
make tf-plan    # preview what will be created
make tf-apply   # create the AWS resources (~2 min)
```

After `tf-apply`, you'll see output like:
```
web_server_public_ip = "54.123.45.67"
ansible_inventory_snippet = ...
```

### 4. Update Ansible inventory
Copy the `ansible_inventory_snippet` output and paste it into `ansible/inventory.ini`, replacing the placeholder IPs.

### 5. Create your Ansible vault (encrypted secrets)
```bash
cd ansible
ansible-vault create group_vars/dbservers/vault.yml
```
Type a vault password, then add:
```yaml
db_password: "YourStrongPasswordHere!"
```
Save and exit (`:wq` in vim).

### 6. Test SSH connectivity
```bash
make ping
```
All three servers should return `pong`.

### 7. Run Ansible to configure everything
```bash
make provision
# Enter your vault password when prompted
```

### 8. Visit your site
```bash
curl http://$(cd terraform && terraform output -raw web_server_public_ip)/health
curl http://$(cd terraform && terraform output -raw web_server_public_ip)/api/items
```

---

## Project structure

```
infra-learning/
├── Makefile                    ← shortcuts for all commands
├── .gitignore
│
├── terraform/
│   ├── main.tf                 ← provider config
│   ├── variables.tf            ← all input variables
│   ├── terraform.tfvars.example
│   ├── vpc.tf                  ← VPC, subnets, route tables
│   ├── security_groups.tf      ← firewall rules per tier
│   ├── instances.tf            ← EC2 instances
│   └── outputs.tf              ← IPs, inventory snippet
│
├── ansible/
│   ├── ansible.cfg             ← Ansible settings
│   ├── inventory.ini           ← server IPs (gitignored)
│   ├── playbook.yml            ← main playbook
│   └── roles/
│       ├── webserver/
│       │   ├── tasks/main.yml      ← install + config Nginx
│       │   ├── handlers/main.yml   ← reload Nginx on change
│       │   └── templates/
│       │       └── nginx.conf.j2   ← reverse proxy config
│       ├── appserver/
│       │   ├── tasks/main.yml      ← install Node.js, deploy app
│       │   ├── handlers/main.yml   ← restart app on change
│       │   └── templates/
│       │       └── server.js.j2    ← Express API
│       └── database/
│           ├── tasks/main.yml      ← install PostgreSQL, seed data
│           └── handlers/main.yml   ← restart postgres on change
│
│   ── container / Kubernetes path ──
│
├── app/                        ← Node source (plain JS, env-driven)
├── web/                        ← static page + nginx config template (envsubst)
├── db/init.sql                 ← Postgres schema
├── docker/{app,web}/Dockerfile ← per-tier image builds
├── kind/
│   ├── cluster.yaml            ← kind cluster (web on localhost:8080)
│   └── metrics-server.yaml     ← --kubelet-insecure-tls patch (for HPA)
├── k8s/                        ← namespace, config/secret, db, app (+HPA), web
└── .github/workflows/ci-cd.yml ← validate → build/push to GHCR → deploy
```

---

## Key concepts explained

### Why separate Terraform and Ansible?

Terraform answers **"what resources exist?"** — it talks to the AWS API to create/destroy infrastructure. Ansible answers **"what's installed and running on each server?"** — it SSHs in and runs commands. Using both is the industry standard.

### What is idempotency?

Running `make provision` twice produces the same result as running it once. Ansible checks current state before acting — if Nginx is already installed and running, it skips the install step. This is critical for production automation.

### What is a Jinja2 template?

The `.j2` files are templates where `{{ variable }}` gets substituted by Ansible at deploy time. The Nginx config template automatically inserts the app server's private IP — no hardcoding.

### Why use ansible-vault?

Secrets (passwords, API keys) should never be committed to git as plaintext. `ansible-vault` encrypts the file so it's safe to commit. Only the vault password — which you keep separately — can decrypt it.

---

## Containers + Kubernetes (local kind)

The same 3-tier app also runs as containers on a local Kubernetes cluster. This
path is independent of AWS — you don't need any cloud resources to use it.

```
Browser → localhost:8080 → web (Nginx, NodePort)
                            → app (Node, Deployment + HPA)
                            → db  (PostgreSQL, StatefulSet + PVC)
```

### Layout

```
app/                       ← extracted Node source (plain JS, env-driven)
web/                       ← static page + nginx config template (envsubst)
db/init.sql                ← schema (also embedded in k8s/01-config.yaml)
docker/{app,web}/Dockerfile
kind/cluster.yaml          ← 1 control-plane + 2 workers, web on localhost:8080
kind/metrics-server.yaml   ← --kubelet-insecure-tls patch (HPA needs metrics)
k8s/                       ← namespace, config/secret, db, app (+HPA), web
.github/workflows/ci-cd.yml
```

### Prerequisites

| Tool | Install |
|------|---------|
| Docker | Docker Desktop |
| kind | `brew install kind` |
| kubectl | `brew install kubectl` |

### Run it locally

```bash
make kind-up      # create the cluster + install metrics-server
make k8s-up       # build images → load into kind → apply manifests
open http://localhost:8080
```

`make k8s-up` builds the images locally and `kind load`s them, so no registry
login is needed. Manifests use `imagePullPolicy: IfNotPresent`, so the loaded
images are used as-is.

Inspect and tear down:

```bash
make k8s-status   # pods, services, HPA
make kind-down    # delete the whole cluster
```

### What this demonstrates

- **Rolling updates** — app/web Deployments use `maxSurge:1, maxUnavailable:0`,
  so a new version rolls out with zero capacity loss. Trigger one with
  `make docker-build kind-load k8s-deploy` after editing the app.
- **Liveness/readiness probes** — app/web hit `/health`; db uses `pg_isready`.
- **Horizontal Pod Autoscaling** — the `app` Deployment scales 2→10 at 60% CPU.
  Load-test it: `kubectl -n infra-learning run load --image=busybox --restart=Never -- \
  /bin/sh -c "while true; do wget -q -O- http://app:3000/api/status; done"` then
  watch `kubectl -n infra-learning get hpa -w`.

### CI/CD (GitHub Actions)

[.github/workflows/ci-cd.yml](.github/workflows/ci-cd.yml) runs three jobs:

1. **validate** (GitHub-hosted) — `kubectl --dry-run=client` on every manifest.
2. **build** (GitHub-hosted) — builds both images and pushes them to **GHCR**
   (`ghcr.io/<owner>/infra-learning-{app,web}`, tagged `:latest` and `:<sha>`)
   on pushes to `main`.
3. **deploy** (**self-hosted**, option A) — runs on *your* machine (the one with
   the kind cluster), pulls the `:<sha>` images, `kind load`s them, and rolls
   them out. Gated to `push` on `main` so fork PRs can't run code on your box.

### Set up the self-hosted runner (one-time)

The deploy job needs a runner on the kind machine, labelled `kind`:

```bash
# GitHub → repo Settings → Actions → Runners → "New self-hosted runner" (macOS)
# Follow the shown ./config.sh command, and when prompted for labels add: kind
# Then start it:
./run.sh                 # foreground, or `./svc.sh install && ./svc.sh start` for a service
```

The runner inherits your shell, so `docker`, `kind`, `kubectl`, `make` and your
kubeconfig (context `kind-infra-learning`) must be available to it.

> **Public-repo safety:** keep repo Settings → Actions → *"Require approval for
> all external contributors"* enabled. The deploy job is already gated to
> `push` on `main`, so `pull_request` events from forks never touch the runner.

Manual rollout still works as a fallback:

```bash
make k8s-deploy TAG=latest
```

---

## Learning challenges (try these once it's working)

1. **Add a load balancer**: Create a second web server in a different availability zone and put an AWS ALB in front of both.
2. **Add HTTPS**: Use Certbot/Let's Encrypt via a new Ansible task to get a TLS certificate.
3. **Extract state to S3**: Move `terraform.tfstate` to an S3 backend with DynamoDB locking.
4. **Add monitoring**: Write an Ansible role that installs Node Exporter and Prometheus.
5. **Auto-generate the inventory**: Use `terraform-inventory` or write a dynamic inventory script so you never copy IPs manually.

---

## Cleanup (avoid AWS charges)

```bash
make teardown
```

This destroys all AWS resources. Double-check in the AWS console that no EC2 instances remain.

---

## Estimated AWS cost

All instances use `t2.micro` which is **free tier eligible** for 750 hours/month. Running 3 instances = 3 × 24h = 72 hours/day — you'll hit the free tier limit in about 10 days. **Run `make teardown` when you're not learning** to avoid charges.
