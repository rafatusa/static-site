# static-site — working notes

## What this is
Static website on AWS EC2. Terraform for infra, **Puppet for configuration
(user explicitly said "dont use ansible")**. Built on Marketplace blueprint
`static-site-ec2@1.0.0`, tailored.

## Approved decisions
- Meta: name/repo `static-site`, aws / us-east-1, target `ec2`, GitHub, branch `main`,
  t3.micro, nginx front. (Approved on card.)
- Design approved at architecture rev 2 + pipeline rev 2.
- Build plan approved.
- AWS probe green: creds valid, us-east-1 available, provisioning permitted,
  default VPC present, 5 EIP / 64 vCPU headroom.

## Configuration layer: Puppet, agent-less
`puppet apply` on the host — no Puppet server (nothing to run or pay for).
CI copies `puppet/` + `site/` over SSH, installs Puppet, applies locally.
- `scripts/install-puppet.sh` — Puppet 8 via official APT release package.
  Ubuntu base repo puppet is old 5.x at a different path (`/usr/bin/puppet`
  vs `/opt/puppetlabs/bin/puppet`). Same class of pitfall as python3.12/deadsnakes.
  Derives codename from /etc/os-release; idempotent early-exit; apt retries.
- `puppet/manifests/site.pp` — installs nginx, syncs `site/` with `purge => true`
  so deletions propagate, writes vhost incl. `/health` (`return 200`),
  `nginx -t` validate before reload, enforces service.
- `--detailed-exitcodes`: 0 = no change, 2 = changes applied. Both are success;
  4/6 are failure. Hence `test $rc -eq 0 -o $rc -eq 2`.
- `ansible/playbook.yml` deleted. validate_project warns about missing ansible/ —
  expected and correct for this project.

## Pre-push self-review (2026-08-26) — found 2 REAL bugs in site.pp
Neither would have been caught by lint (both are syntactically valid Puppet);
both would have failed at apply time on the host. Fixed before first push:
1. **Duplicate declaration.** `file { '/var/www/site': }` AND
   `file { '/var/www/site/': }` — Puppet normalises the trailing slash, so these
   are the same resource. `puppet apply` aborts with "Duplicate declaration:
   File[/var/www/site] is already declared". Configure would have died before
   nginx was touched. Collapsed into ONE file resource.
2. **`mode => '0644'` on a recursive dir sync.** Strips the traverse (+x) bit
   from the document root, so nginx returns **403 on every request** — configure
   would look successful and verify would fail on /health. Added an explicit
   `find -type d -exec chmod 0755` exec subscribed to the file resource.
LESSON: `puppet parser validate` only checks SYNTAX. Resource-graph errors
(duplicates) and semantic errors (permissions) need a real apply or a careful read.

## Pipeline history
- rev 3: removed bogus `test -f site/health` lint check (nginx serves /health
  from the vhost; the check would have failed lint on EVERY run); runner installs
  Puppet 8 from official repo so it parses with the same version the host applies;
  added SSH-readiness wait (terraform apply returns before sshd is up).
- rev 4: lint no longer hardcodes `puppet8-release-jammy.deb`. Runner is
  `ubuntu-latest` (now noble, not jammy) — a jammy release package on a noble
  runner is the wrong repo. Now derives $VERSION_CODENAME like the host script.

## Gate status (workspace @ 18 files, pipeline rev 4)
- validate_project: PASS.
  - warn "no ansible/*.yml" → deliberate, see above.
  - warn x2 "known issue may apply" → both are npm/`actions/setup-node` lockfile
    failures. No Node, no npm, no setup-node in this project. Not applicable.
- test_project: SKIPPED — language 'unknown' (static HTML), sandbox has no recipe
  and no Puppet. Sandbox gap, not a defect. Do NOT reshape the project to satisfy it.
  CONSEQUENCE: the lint stage has never actually executed anywhere. CI is its
  first real run — expect the first red, if any, to be in lint or configure.

## Gotchas hit
- Two approval cards expired without a decision earlier (meta, then the pipeline
  amendment). Nothing was applied either time; re-sent on request. Don't route
  around a gate — just re-send.

## Next
- create_repo_and_push (approval) → deploy (approval) → wait_for_run.
- No extra pipeline secrets needed: PROJECT_NAME, TF_STATE_BUCKET, SSH_*, AWS_*
  are all platform-provided. Nothing to set_pipeline_secret.
- After green: verify `http://<eip>/` and `http://<eip>/health`.
