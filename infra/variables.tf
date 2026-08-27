variable "project_name" {
  description = "Project name — prefixes every resource and tags Project."
  type        = string
}

variable "ssh_public_key" {
  description = "Platform-managed deploy key (SSH_PUBLIC_KEY secret)."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance size for the application server."
  type        = string
  default     = "t3.micro"
}

# DELIBERATE DEFAULT, not an oversight.
#
# The configure stage SSHes in from a GitHub-hosted runner, and those come from
# a large rotating public IP range that GitHub reserves the right to change.
# Pinning a narrower CIDR here would break the deploy on some future run with
# an opaque connection timeout.
#
# Exposing it as a variable makes the exposure explicit and reviewable: set it
# to a specific CIDR if you move to self-hosted runners or a bastion. tfsec
# reports this as MEDIUM (aws-vpc-no-public-ingress-sgr) and the security stage
# deliberately does not suppress it — see .udap/notes.md.
variable "ssh_allowed_cidr" {
  description = "CIDR permitted to reach SSH. Default is open for GitHub-hosted runners."
  type        = string
  default     = "0.0.0.0/0"
}
