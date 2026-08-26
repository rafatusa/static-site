# static-site

Production-ready static website hosting on AWS EC2.

Built from a UDAP Marketplace production blueprint — infrastructure (Terraform),
configuration (Ansible/CI) and the deployment pipeline are inherited; the
application code in this repository is yours to evolve.

**Stack:** HTML/CSS/JS · nginx · Ubuntu 22.04 EC2 · Terraform · Ansible

- `GET /health` — health probe used by the deploy pipeline's verify stage
- `GET /` — landing page (replace it with your application)
