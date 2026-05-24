# infra-learning

A 3-tier web application infrastructure built with **Terraform** (provision) and **Ansible** (configure) on AWS free tier. Built to learn infrastructure skills for DevOps internships.

```
Internet → Nginx (web) → Node.js (app) → PostgreSQL (db)
           public subnet   private subnet   db subnet
```

## What you'll learn

- **Terraform**: VPCs, subnets, security groups, EC2 instances, state management
- **Ansible**: roles, handlers, Jinja2 templates, vault (secrets), idempotent tasks
- **Networking**: public vs private subnets, route tables, internet gateways
- **Security**: least-privilege security groups, SSH bastion pattern, secrets management
- **Linux**: systemd services, firewalld, PostgreSQL setup

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
└── ansible/
    ├── ansible.cfg             ← Ansible settings
    ├── inventory.ini           ← server IPs (gitignored)
    ├── playbook.yml            ← main playbook
    └── roles/
        ├── webserver/
        │   ├── tasks/main.yml      ← install + config Nginx
        │   ├── handlers/main.yml   ← reload Nginx on change
        │   └── templates/
        │       └── nginx.conf.j2   ← reverse proxy config
        ├── appserver/
        │   ├── tasks/main.yml      ← install Node.js, deploy app
        │   ├── handlers/main.yml   ← restart app on change
        │   └── templates/
        │       └── server.js.j2    ← Express API
        └── database/
            ├── tasks/main.yml      ← install PostgreSQL, seed data
            └── handlers/main.yml   ← restart postgres on change
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
