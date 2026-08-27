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
# ── HOW rspec-puppet ACTUALLY FINDS THE MANIFEST (verified, not assumed) ─────
#
# Read rspec-puppet-5.0.0/lib/rspec-puppet/support.rb:
#
#     def site_pp_str
#       return '' unless (path = adapter.manifest)
#       ... File.read(path) / concatenate *.pp if it is a directory ...
#     end
#
# and adapters.rb:
#
#     def manifest
#       m = current_environment.manifest
#       m == Puppet::Node::Environment::NO_MANIFEST ? nil : m
#     end
#
# rspec-puppet INLINES the manifest's source into the compiled code. It builds
# `current_environment` IN MEMORY and therefore NEVER READS environment.conf
# from disk. Without `c.manifest`, current_environment.manifest is
# :no_manifest, adapter.manifest is nil, site_pp_str returns '', and the
# catalog contains only Stage[main], Class[Settings], Class[main] — while
# reporting a successful compile and 100% coverage of zero resources.
#
# Confirmed empirically with this exact gem version:
#     c.manifest unset -> ENVMANIFEST=:no_manifest, catalog COUNT=3
#     c.manifest set   -> ENVMANIFEST="<path>",     catalog COUNT=10
#
# `c.manifest` EXISTS in rspec-puppet 5. Only `manifest_dir=` was removed in
# v4 — do not conclude from a `manifest_dir=` NoMethodError that `manifest=`
# is gone too. That inference cost several CI rounds on this project.
#
# environment.conf is NOT used by this harness and must not be added: it does
# nothing here, and earlier attempts to drive resolution through it produced
# the empty-catalog failure above.
#
# ── OTHER rspec-puppet 5 API NOTES ───────────────────────────────────────────
#
#   * `manifest_dir=` was REMOVED in rspec-puppet 4.
#   * `environment` is NOT an RSpec.configure attribute — it is per-example,
#     declared with `let(:environment)`. Setting it here raises NoMethodError.

require 'rspec-puppet'
require 'rspec-puppet/coverage'
require 'fileutils'

# The manifest declares 7 resources. The guard in spec/hosts/site_spec.rb only
# needs to distinguish "manifest loaded" from "manifest missing", so a low,
# stable floor is correct — it must not become a second coverage metric.
#
# An UNLOADED manifest still yields Puppet's own boilerplate (Stage[main],
# Class[Settings], Class[main]), so this floor must sit above 3 once that
# boilerplate is filtered out.
MINIMUM_EXPECTED_RESOURCES = 5

REPO_ROOT    = File.expand_path(File.join(__dir__, '..')).freeze
FIXTURE_PATH = File.join(__dir__, 'fixtures').freeze
TEST_ENV     = 'production'.freeze

ENV_ROOT      = File.join(FIXTURE_PATH, TEST_ENV).freeze
ENV_MANIFESTS = File.join(ENV_ROOT, 'manifests').freeze
ENV_MODULES   = File.join(ENV_ROOT, 'modules').freeze
FileUtils.mkdir_p(ENV_MANIFESTS)
FileUtils.mkdir_p(ENV_MODULES)

# environment.conf is never read by rspec-puppet (see notes above). Remove any
# stale one so a leftover from an earlier revision cannot mislead a future
# reader into thinking it is load-bearing.
FileUtils.rm_f(File.join(ENV_ROOT, 'environment.conf'))

real_manifest = File.join(REPO_ROOT, 'puppet', 'manifests', 'site.pp')
raise "manifest not found: #{real_manifest}" unless File.exist?(real_manifest)

# Copy and refresh on every run, so the suite always compiles exactly the file
# the host applies.
manifest_copy = File.join(ENV_MANIFESTS, 'site.pp')
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
  c.module_path     = ENV_MODULES

  # THE LOAD-BEARING SETTING. Without this the catalog is empty — see the
  # detailed notes at the top of this file before changing or removing it.
  # A directory is valid: rspec-puppet concatenates every *.pp inside it.
  c.manifest = ENV_MANIFESTS

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
  # zero resources and sails straight through this floor.
  c.after(:suite) do
    RSpec::Puppet::Coverage.report!(90)
  end
end
