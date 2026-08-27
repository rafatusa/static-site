# static-site

Static website hosting on AWS EC2.

Built from a UDAP Marketplace production blueprint (`static-site-ec2@1.0.0`) and
tailored: the configuration layer is **Puppet**, applied agent-less on the host.

**Stack:** HTML/CSS · nginx · Ubuntu 22.04 EC2 · Terraform · Puppet 8

- `GET /` — landing page
- `GET /health` — health probe used by the deploy pipeline's verify stage

## Layout

| Path | Purpose |
|---|---|
| `site/` | The website content. This is what you edit. |
| `puppet/manifests/site.pp` | Installs nginx, syncs `site/`, writes the vhost. |
| `spec/` | rspec-puppet unit tests for the manifest. |
| `infra/` | Terraform: security group, EC2 instance, Elastic IP. |
| `scripts/install-puppet.sh` | Installs Puppet 8 on the host from the official APT repo. |
| `.udap/pipeline.yaml` | Pipeline source of truth. The workflows are rendered from it. |

## Making a change

Edit `site/`, commit, deploy. The manifest declares `purge => true` on the
document root, so files deleted from `site/` are removed from the host too.

Re-running is idempotent: an unchanged host exits 0, a changed host exits 2 —
both are success.

## Quality gates

Every deploy runs these before any infrastructure is touched. `provision` is
gated on both `test` and `security` passing.

**lint**
- `puppet parser validate` — syntax
- `puppet-lint` — style and structure
- `puppet apply --noop` — compiles the full catalog, which is what catches
  unknown variables and duplicate resource declarations. `parser validate`
  alone cannot: it parses without evaluating.
- `shellcheck` on the installer script

**test** — `rspec-puppet`, with a **90% resource-coverage floor** that fails the
build when it drops. The suite compiles the manifest in-process and asserts on
the resulting catalog, including regression tests for two bugs that previously
reached production: the heredoc escape that turned nginx's `$uri` into a Puppet
variable, and a recursive `0644` that stripped the document root's traverse bit
and made nginx return 403 on every request.

**security** — findings are printed in full; **HIGH and CRITICAL fail the build**,
MEDIUM and LOW are reported for review.
- `gitleaks` — secrets across the full git history
- `tfsec` — Terraform misconfiguration
- `trivy` — filesystem vulnerabilities, misconfiguration and secrets

Running the unit tests locally, with Puppet 8 installed:

```sh
/opt/puppetlabs/puppet/bin/gem install --no-document rspec-puppet rspec puppetlabs_spec_helper
/opt/puppetlabs/puppet/bin/rspec
```

## Security posture

- IMDSv2 is **required** — instance metadata is unreachable without a session
  token, so an SSRF cannot read instance credentials.
- The root EBS volume is **encrypted** at rest.
- SSH exposure is the `ssh_allowed_cidr` variable. It defaults to `0.0.0.0/0`
  because GitHub-hosted runners connect from a large rotating IP range; narrow
  it if you move to self-hosted runners or a bastion.
- **No TLS.** The site is HTTP-only on port 80. A public CA will not issue a
  certificate for a bare IP address, so HTTPS requires a domain name first —
  either Let's Encrypt via certbot on the instance, or ACM behind a load
  balancer. Port 443 is already open in the security group.

## Tier

Tier 1 by design: a single instance, no autoscaling, HA, CDN or monitoring.
