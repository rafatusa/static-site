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
