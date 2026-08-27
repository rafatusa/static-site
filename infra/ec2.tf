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
# The security stage BLOCKS on HIGH/CRITICAL. Four rule-scoped suppressions
# live on the blocks below, each stating its own reason. Everything else fails
# the build — verified against tfsec v1.28.13 on this exact directory:
#   with the ignores            -> ignored 9,  critical 0, exit 0
#   + an unencrypted EBS volume -> high 1,                 exit 1
#
# NOTE ON PLACEMENT: `tfsec:ignore` applies to the block it IMMEDIATELY
# precedes and does NOT cascade from the enclosing `resource` block down to
# nested ingress/egress rules. A single ignore on the resource was measured and
# left both public-web rules unsuppressed. Each rule block needs its own.
#
# Do not broaden these to a file-level ignore, and do not add --soft-fail to
# the pipeline. A new finding is either fixed, or gets a new single-rule
# ignore with its own written justification.
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_security_group" "app" {
  name        = "${var.project_name}-sg"
  description = "SSH + public web for ${var.project_name}"

  # ACCEPTED aws-ec2-no-public-ingress-sgr:
  # SSH must be reachable from GitHub-hosted runners, which draw from a large
  # published range that Microsoft rotates continuously; pinning a CIDR breaks
  # the configure stage the next time the range changes. Mitigated by key-only
  # auth (no password, no root login) on a host that serves only static files.
  # Sourced from a variable so tightening it is a one-value change once a fixed
  # egress IP (self-hosted runner or bastion) exists.
  # tfsec:ignore:aws-ec2-no-public-ingress-sgr
  ingress {
    description = "SSH from the CI runner"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  # ACCEPTED aws-ec2-no-public-ingress-sgr:
  # This is a PUBLIC WEBSITE. Serving HTTP to the internet is the purpose of
  # the host, not an oversight — a restrictive CIDR here would mean nobody can
  # reach the site. Not a risk being tolerated; a requirement being met.
  # tfsec:ignore:aws-ec2-no-public-ingress-sgr
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # ACCEPTED aws-ec2-no-public-ingress-sgr:
  # Same rationale as port 80. Open ahead of TLS being configured — HTTPS needs
  # a domain name before a public CA will issue a certificate, so nothing is
  # listening on 443 yet.
  # tfsec:ignore:aws-ec2-no-public-ingress-sgr
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # ACCEPTED aws-ec2-no-public-egress-sgr:
  # The host must reach apt archives, apt.puppet.com and github.com to be
  # configured at all. Those are CDN-backed with no stable address set, so an
  # egress allowlist would fail unpredictably on upstream IP changes. Outbound
  # from a static-file host carries no data-exfiltration surface of its own.
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
