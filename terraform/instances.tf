# Fetch the latest Amazon Linux 2023 AMI — no hardcoded IDs
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ─── Web Server (public subnet) ───────────────────────────────────────────────

resource "aws_instance" "web" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.web.id]
  key_name               = var.key_pair_name

  tags = {
    Name        = "${var.project_name}-web"
    Role        = "webserver"
    Environment = var.environment
  }
}

# ─── App Server (private subnet) ──────────────────────────────────────────────

resource "aws_instance" "app" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.app.id]
  key_name               = var.key_pair_name

  tags = {
    Name        = "${var.project_name}-app"
    Role        = "appserver"
    Environment = var.environment
  }
}

# ─── Database Server (db subnet) ──────────────────────────────────────────────

resource "aws_instance" "db" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.db.id]
  key_name               = var.key_pair_name

  tags = {
    Name        = "${var.project_name}-db"
    Role        = "database"
    Environment = var.environment
  }
}

resource "aws_eip" "web" {
  instance = aws_instance.web.id
  domain   = "vpc"

  tags = {
    Name = "${var.project_name}-web-eip"
  }
}

resource "aws_eip" "app" {
  instance = aws_instance.app.id
  domain   = "vpc"
  tags = {
    Name = "${var.project_name}-app-eip"
  }
}

resource "aws_eip" "db" {
  instance = aws_instance.db.id
  domain   = "vpc"
  tags = {
    Name = "${var.project_name}-db-eip"
  }
}
