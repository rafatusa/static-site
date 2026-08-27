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
# ── FIXTURE LAYOUT: why it is built this way (each line is a fixed bug) ───────
#
#   * `manifest_dir=` / `manifest=` were REMOVED from RSpec.configure in
#     rspec-puppet 4. Manifests resolve ONLY through environmentpath.
#
#   * `environment` is NOT an RSpec.configure attribute — it is per-example,
#     declared with `let(:environment)`. Setting it here raises NoMethodError.
#
#   * A directory under environmentpath is NOT an environment until it contains
#     `environment.conf`. Without one Puppet compiles an EMPTY catalog that
#     still "succeeds": every expectation fails with "would contain ..." and the
#     coverage report claims 100% of zero resources.
#
#   * The manifest is COPIED IN, never symlinked. Puppet enumerates real files
#     when loading a manifest directory; a symlinked site.pp is skipped, which
#     yields a catalog holding only Puppet's own boilerplate (Stage[main],
#     Class[Settings], Class[main]) — 3 resources, no nginx, no files. The copy
#     is refreshed on every run from the real manifest, so the suite always
#     tests exactly the file the host applies.
#
#   * `manifest` points at the FILE, not the directory. This manifest is a
#     bare-resource site manifest (no node block), which is what `puppet apply`
#     consumes on the host; naming the file directly removes any dependency on
#     directory-glob semantics.

require 'rspec-puppet'
require 'rspec-puppet/coverage'
require 'fileutils'

# The manifest declares well over this many resources. The guard in
# spec/hosts/site_spec.rb only needs to distinguish "environment loaded" from
# "environment empty", so a low, stable floor is correct — it must not become a
# second coverage metric that needs maintaining.
#
# NOTE: an unloaded environment still yields 3 boilerplate resources
# (Stage[main], Class[Settings], Class[main]), so this floor must sit above 3.
MINIMUM_EXPECTED_RESOURCES = 5

REPO_ROOT    = File.expand_path(File.join(__dir__, '..')).freeze
FIXTURE_PATH = File.join(__dir__, 'fixtures').freeze
TEST_ENV     = 'production'.freeze

ENV_ROOT      = File.join(FIXTURE_PATH, TEST_ENV).freeze
env_manifests = File.join(ENV_ROOT, 'manifests')
env_modules   = File.join(ENV_ROOT, 'modules')
FileUtils.mkdir_p(env_manifests)
FileUtils.mkdir_p(env_modules)

real_manifest = File.join(REPO_ROOT, 'puppet', 'manifests', 'site.pp')
raise "manifest not found: #{real_manifest}" unless File.exist?(real_manifest)

# COPY (not symlink) — see the fixture-layout notes above.
manifest_copy = File.join(env_manifests, 'site.pp')
FileUtils.rm_f(manifest_copy)
FileUtils.cp(real_manifest, manifest_copy)

# environment.conf naming the manifest FILE directly.
File.write(
  File.join(ENV_ROOT, 'environment.conf'),
  <<~CONF,
    manifest = #{manifest_copy}
    modulepath = #{env_modules}
  CONF
)

# Fail fast and loudly if the copy did not land — a silent miss here is what
# produces the "empty catalog, 100% coverage" trap downstream.
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
