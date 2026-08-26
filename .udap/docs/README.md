# Static Website on AWS EC2

A plain HTML/CSS/JS site served by nginx on a dedicated Ubuntu EC2 instance — no build step, no framework, no lock-in.

## What you inherit

- EC2 + Elastic IP + security group as Terraform under `infra/`
- Ansible configuration: nginx with an nginx-served /health endpoint
- Health-checked verify stage

## What the Build Agent tailors

- Everything under `site/` — your pages, styles and scripts
- Instance size, region

## Deploy behaviour

The pipeline provisions infrastructure with Terraform (state lives in the
platform-managed bucket, keyed by project), configures the server, and verifies
`/health` before the run goes green. Destroy tears down everything the template
created — the repository and its configuration survive for redeploys.
