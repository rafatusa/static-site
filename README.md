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

**lint** — blocking
- `puppet parser validate` — syntax
- `puppet-lint` — style and structure
- `puppet apply --noop` — compiles the full catalog, which is what catches
  unknown variables and duplicate resource declarations. `parser validate`
  alone cannot: it parses without evaluating.
- `shellcheck` on the installer script

**test** — blocking. `rspec-puppet`, with a **90% resource-coverage floor** that
fails the build when it drops. The suite compiles the manifest in-process and
asserts on the resulting catalog, including regression tests for two bugs that
previously reached production: the heredoc escape that turned nginx's `$uri`
into a Puppet variable, and a recursive `0644` that stripped the document root's
traverse bit and made nginx return 403 on every request. It also fails outright
on an empty catalog — 100% coverage of zero resources passes any floor while
asserting nothing.

**security** — ⚠️ **REPORT-ONLY. This stage cannot fail the build.**
- `gitleaks` — secrets across the full git history
- `tfsec` — Terraform misconfiguration
- `trivy` — filesystem vulnerabilities, misconfiguration and secrets

**configure** — blocking. After Puppet applies, asserts over SSH that **IMDSv2
is enforced**: an unauthenticated metadata request returns `401`, and the token
endpoint returns `200`. Both assertions are needed — the `401` alone would also
be produced by an unreachable IMDS, which would prove nothing.

**verify** — blocking. `/health` and `/` return 200, the document root is not
browsable, and `/` serves `text/html` rather than an error body with a 200 code.

> **Read this before trusting a green pipeline.**
>
> The security stage was made non-blocking on 2026-08-27 at the project owner's
> explicit direction, overriding a recommendation to triage the findings
> individually and suppress only the deliberate ones. It was **not** made
> non-blocking because the findings were reviewed and accepted.
>
> Consequently a green ✅ on this pipeline says nothing about the security of
> this repository. No finding at any severity — including a committed
> credential — will stop a deploy. Read the stage's log output instead.
>
> **Currently outstanding, un-suppressed and un-gated:**
>
> | ID | Severity | Location | Finding |
> |---|---|---|---|
> | `AWS-0104` | CRITICAL | `infra/ec2.tf:63` | Unrestricted egress to `0.0.0.0/0` |
> | `AWS-0107` | HIGH | `infra/ec2.tf:39` | Unrestricted ingress (`var.ssh_allowed_cidr`) |
>
> Both correspond to deliberate Tier-1 choices documented under Security
> posture below — egress is required for apt/Puppet/GitHub, and the SSH CIDR is
> open because GitHub-hosted runners rotate IP addresses. They are accepted by
> inaction rather than by review.
>
> To restore blocking: in `.udap/pipeline.yaml`, drop the `--exit-code 0` /
> `--soft-fail` / trailing `exit 0` from each scanner step. The two findings
> above are then what must be fixed or narrowly suppressed.

Running the unit tests locally, with Puppet 8 installed:

```sh
sudo /opt/puppetlabs/puppet/bin/gem install --no-document 'rspec-puppet:~> 5.0' rspec
sudo /opt/puppetlabs/puppet/bin/rspec --default-path spec spec/hosts
```

## Security posture

- IMDSv2 is **required** — instance metadata is unreachable without a session
  token, so an SSRF cannot read instance credentials. Asserted on the host by
  the configure stage.
- The root EBS volume is **encrypted** at rest.
- SSH exposure is the `ssh_allowed_cidr` variable. It defaults to `0.0.0.0/0`
  because GitHub-hosted runners connect from a large rotating IP range; narrow
  it if you move to self-hosted runners or a bastion.
- Egress is unrestricted, which the instance needs for apt, the Puppet APT repo
  and GitHub.
- **No TLS.** The site is HTTP-only on port 80. A public CA will not issue a
  certificate for a bare IP address, so HTTPS requires a domain name first —
  either Let's Encrypt via certbot on the instance, or ACM behind a load
  balancer. Port 443 is already open in the security group.
- **Scanner findings are not gated.** See the warning under Quality gates.

## Tier

Tier 1 by design: a single instance, no autoscaling, HA, CDN or monitoring.
