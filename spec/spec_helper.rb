# rspec-puppet harness for the static-site manifest.
#
# This suite compiles puppet/manifests/site.pp IN PROCESS and asserts on the
# resulting catalog. It is the shift-left gate for the two failure classes that
# actually broke this project's deploys:
#
#   1. Evaluation errors (unknown variables — the `$uri` heredoc bug), which
#      `puppet parser validate` structurally cannot catch because it only parses.
#   2. Duplicate resource declarations (the '/var/www/site' vs '/var/www/site/'
#      bug), which abort `puppet apply` on the host.
#
# Both now fail on the runner in seconds instead of after provisioning an EC2
# instance and SSHing into it.
#
# ── FIXTURE LAYOUT: KEEP IT BORING ───────────────────────────────────────────
#
# The layout below is Puppet's DEFAULT directory-environment layout and nothing
# more:
#
#     spec/fixtures/                <- environmentpath
#       production/
#         manifests/site.pp         <- copied from puppet/manifests/site.pp
#         modules/
#
# There is deliberately NO environment.conf. This was verified empirically
# against Puppet 8 (`puppet catalog compile <node> --environmentpath ...` on a
# real host): with just manifests/site.pp present and no environment.conf,
# Puppet loads all seven declared resources. Puppet's default `manifest`
# setting already points at the environment's `manifests` DIRECTORY.
#
# Writing an environment.conf that overrides `manifest` (or `modulepath`) is
# what broke this harness repeatedly: overriding `manifest` to name a file, or
# setting a modulepath that drops $basemodulepath, defeats the default
# resolution and yields a catalog containing only Puppet's own boilerplate
# (Stage[main], Class[Settings], Class[main]) while still "compiling
# successfully". If a future change makes the catalog come back near-empty, the
# first suspect is an added environment.conf — not the manifest.
#
# ── rspec-puppet 5 API NOTES ─────────────────────────────────────────────────
#
#   * `manifest_dir=` / `manifest=` were REMOVED from RSpec.configure in
#     rspec-puppet 4. Manifests resolve ONLY through environmentpath.
#
#   * `environment` is NOT an RSpec.configure attribute — it is per-example,
#     declared with `let(:environment)`. Setting it here raises NoMethodError.

require 'rspec-puppet'
require 'rspec-puppet/coverage'
require 'fileutils'

# The manifest declares 7 resources. The guard in spec/hosts/site_spec.rb only
# needs to distinguish "environment loaded" from "environment empty", so a low,
# stable floor is correct — it must not become a second coverage metric.
#
# An UNLOADED environment still yields Puppet's own boilerplate (Stage[main],
# Class[Settings], Class[main]), so this floor must sit above 3 once that
# boilerplate is filtered out.
MINIMUM_EXPECTED_RESOURCES = 5

REPO_ROOT    = File.expand_path(File.join(__dir__, '..')).freeze
FIXTURE_PATH = File.join(__dir__, 'fixtures').freeze
TEST_ENV     = 'production'.freeze

ENV_ROOT      = File.join(FIXTURE_PATH, TEST_ENV).freeze
env_manifests = File.join(ENV_ROOT, 'manifests')
env_modules   = File.join(ENV_ROOT, 'modules')
FileUtils.mkdir_p(env_manifests)
FileUtils.mkdir_p(env_modules)

# Defensive: a stale environment.conf left by an earlier revision silently
# breaks manifest resolution (see the layout notes above). Never ship one.
FileUtils.rm_f(File.join(ENV_ROOT, 'environment.conf'))

real_manifest = File.join(REPO_ROOT, 'puppet', 'manifests', 'site.pp')
raise "manifest not found: #{real_manifest}" unless File.exist?(real_manifest)

# Copy (not symlink) and refresh on every run, so the suite always compiles
# exactly the file the host applies.
manifest_copy = File.join(env_manifests, 'site.pp')
FileUtils.rm_f(manifest_copy)
FileUtils.cp(real_manifest, manifest_copy)

unless File.file?(manifest_copy) && File.size(manifest_copy) > 0
  raise "fixture manifest was not staged at #{manifest_copy}"
end

# The manifest declares File resources whose `source` points into the deploy
# root. Puppet resolves `source` during CATALOG COMPILATION, not only at apply
# time, so the harness needs the same layout the host gets from scp — the same
# reason the lint stage's noop step stages it. Without this the compile fails
# on File[/var/www/site].
DEPLOY_ROOT = '/tmp/udap-deploy'.freeze
begin
  FileUtils.mkdir_p(DEPLOY_ROOT)
  FileUtils.rm_rf(File.join(DEPLOY_ROOT, 'site'))
  FileUtils.cp_r(File.join(REPO_ROOT, 'site'), File.join(DEPLOY_ROOT, 'site'))
rescue SystemCallError => e
  warn "could not stage #{DEPLOY_ROOT}: #{e.message}"
end

RSpec.configure do |c|
  c.environmentpath = FIXTURE_PATH
  c.module_path     = env_modules

  # Deterministic facts. The manifest targets Ubuntu on EC2; pinning the facts
  # means a test failure is a manifest change, never a runner change.
  c.default_facts = {
    'os' => {
      'family'  => 'Debian',
      'name'    => 'Ubuntu',
      'release' => { 'full' => '22.04', 'major' => '22' },
    },
    'osfamily'               => 'Debian',
    'operatingsystem'        => 'Ubuntu',
    'operatingsystemrelease' => '22.04',
    'networking'             => { 'ip' => '10.0.0.10' },
    'ipaddress'              => '10.0.0.10',
    'path'                   => '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
  }

  # COVERAGE FLOOR — the build fails below this.
  #
  # rspec-puppet resource coverage is a real, honestly-denominated metric: the
  # share of resources DECLARED in the compiled catalog that at least one
  # example asserts on. (This is not statement coverage of application code —
  # this project has none. Reporting a fabricated percentage over static HTML
  # would be worse than reporting nothing.)
  #
  # The vacuous-pass problem is handled by a normal example in
  # spec/hosts/site_spec.rb, NOT here: an empty catalog reports "100.00%" of
  # zero resources and sails straight through this floor. That guard is a plain
  # expectation rather than logic in this hook so it cannot itself break the
  # suite the way a call into coverage internals would.
  c.after(:suite) do
    RSpec::Puppet::Coverage.report!(90)
  end
end
