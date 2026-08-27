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
# API NOTES (rspec-puppet 5 — learned the hard way, do not "simplify" these):
#
#   * `manifest_dir=` and `manifest=` were REMOVED in rspec-puppet 4. Manifests
#     are resolved ONLY through environmentpath:
#         <environmentpath>/<environment>/manifests/*.pp
#
#   * An environment directory is NOT an environment until it contains an
#     `environment.conf`. Without one Puppet compiles the node against an EMPTY
#     site manifest: the catalog builds successfully but contains ZERO of our
#     resources, so every expectation fails with "expected that the catalogue
#     would contain ..." and coverage reports a meaningless 100% of nothing.
#     This file writes environment.conf explicitly for that reason.
#
#   * `environment` is NOT an RSpec.configure attribute — it is a per-example
#     setting, declared with `let(:environment)` inside the example group.
#     Setting it here raises NoMethodError.
#
#   * Only genuinely global settings belong in this block: environmentpath,
#     module_path, default_facts.

require 'rspec-puppet'
require 'rspec-puppet/coverage'
require 'fileutils'

# The manifest declares well over this many resources. The guard in
# spec/hosts/site_spec.rb only needs to distinguish "environment loaded" from
# "environment empty", so a low, stable floor is correct here — it must not
# become a second coverage metric that needs maintaining.
MINIMUM_EXPECTED_RESOURCES = 5

REPO_ROOT    = File.expand_path(File.join(__dir__, '..')).freeze
FIXTURE_PATH = File.join(__dir__, 'fixtures').freeze
TEST_ENV     = 'production'.freeze

# Build a REAL puppet environment at <fixtures>/production:
#
#   production/
#     environment.conf   <- without this the env is inert and the catalog is empty
#     manifests/site.pp  <- link to the manifest the host actually applies
#
ENV_ROOT = File.join(FIXTURE_PATH, TEST_ENV).freeze
env_manifests = File.join(ENV_ROOT, 'manifests')
env_modules   = File.join(ENV_ROOT, 'modules')
FileUtils.mkdir_p(env_manifests)
FileUtils.mkdir_p(env_modules)

# environment.conf: point `manifest` at this environment's manifests dir. Puppet
# treats a directory under environmentpath as an environment only when this file
# resolves the site manifest; otherwise it compiles an empty catalog.
File.write(
  File.join(ENV_ROOT, 'environment.conf'),
  <<~CONF,
    manifest = ./manifests
    modulepath = ./modules
  CONF
)

real_manifest = File.join(REPO_ROOT, 'puppet', 'manifests', 'site.pp')
link_target   = File.join(env_manifests, 'site.pp')

raise "manifest not found: #{real_manifest}" unless File.exist?(real_manifest)

FileUtils.rm_f(link_target)
begin
  FileUtils.ln_s(real_manifest, link_target)
rescue NotImplementedError, Errno::EPERM
  # Filesystems without symlink support: fall back to a copy.
  FileUtils.cp(real_manifest, link_target)
end

# The manifest declares File resources whose `source` points into the deploy
# root. Puppet resolves `source` during CATALOG COMPILATION, not just at apply
# time, so the harness needs the same layout the host gets from scp — exactly
# the same reason the lint stage's noop step stages it. Without this the
# compile fails on File[/var/www/site].
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
    'path'                   => '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
  }

  # COVERAGE FLOOR — the build fails below this.
  #
  # rspec-puppet resource coverage is a real, honestly-denominated metric: the
  # share of resources DECLARED in the compiled catalog that at least one
  # example asserts on. (Note this is not statement coverage of application
  # code — this project has no application code. Reporting a fabricated
  # percentage over static HTML would be worse than reporting nothing.)
  #
  # The vacuous-pass problem is handled in spec/hosts/site_spec.rb by a normal
  # example that asserts the catalog is non-empty, NOT here: an empty catalog
  # reports "100.00%" coverage of zero resources and sails through this floor.
  # That guard is deliberately a plain expectation rather than logic in this
  # hook, so it cannot itself break the suite the way a coverage-internals call
  # would.
  c.after(:suite) do
    RSpec::Puppet::Coverage.report!(90)
  end
end
