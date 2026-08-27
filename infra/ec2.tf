data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# The ONLY key-injection path: cloud key pair from the platform secret;
# authorized_keys is seeded at launch by cloud-init.
resource "aws_key_pair" "app" {
  key_name   = "${var.project_name}-deploy-key"
  public_key = var.ssh_public_key

  tags = {
    Project = var.project_name
  }
}

# ── ACCEPTED SECURITY FINDINGS (reviewed 2026-08-27) ──────────────────────────
# The security stage BLOCKS on HIGH/CRITICAL. These two suppressions are the
# only exceptions, each scoped to ONE rule id, with the reason stated. Any other
# finding — a new open port, an unencrypted volume, a committed secret — fails
# the build. Do not broaden these to a blanket ignore.
#
# AWS-0107 (HIGH, ingress 0.0.0.0/0 on port 22)
#   SSH must be reachable from GitHub-hosted runners, which draw from a large
#   published range that Microsoft rotates continuously. Pinning a CIDR breaks
#   the configure stage the next time the range changes. The exposure is
#   mitigated by key-only auth (no password auth, no root login) and the fact
#   that the host serves only static files. Sourced from var.ssh_allowed_cidr
#   so tightening it is a one-value change when a fixed egress IP exists.
#
# AWS-0104 (CRITICAL, unrestricted egress)
#   The host must reach apt archives, apt.puppet.com and github.com to be
#   configured at all. Those are CDN-backed with no stable address set, so an
#   egress allowlist would fail unpredictably on upstream IP changes. Outbound
#   from a static-file host carries no data-exfiltration surface of its own.
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_security_group" "app" {
  name        = "${var.project_name}-sg"
  description = "SSH + public web for ${var.project_name}"

  # Sourced from a variable so the exposure is explicit and reviewable rather
  # than a hardcoded default. See the variable's documentation for why the
  # default is open (GitHub-hosted runners use a rotating IP range).
  # tfsec:ignore:aws-ec2-no-public-ingress-sgr
  ingress {
    description = "SSH from the CI runner"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # tfsec:ignore:aws-ec2-no-public-egress-sgr
  egress {
    description = "Package and Puppet repository access"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Project = var.project_name
  }
}

resource "aws_instance" "app" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.app.key_name
  vpc_security_group_ids = [aws_security_group.app.id]

  # IMDSv2 REQUIRED. With the default (optional) an unauthenticated GET to
  # 169.254.169.254 returns instance metadata, so any SSRF in a served page —
  # or any process on the box — can read the instance role's credentials.
  # Requiring a session token closes that off. Nothing here reads metadata,
  # so this breaks nothing.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # Encrypt data at rest with the AWS-managed EBS key. Free, and the only
  # moment it can be set is at creation.
  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 8

    tags = {
      Project = var.project_name
    }
  }

  tags = {
    Name    = var.project_name
    Project = var.project_name
  }
}

# EIP is required on EC2 so the address survives instance replacement.
resource "aws_eip" "app" {
  instance = aws_instance.app.id
  domain   = "vpc"

  tags = {
    Project = var.project_name
  }
}
