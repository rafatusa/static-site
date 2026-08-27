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
# API NOTE: rspec-puppet 4 REMOVED `manifest_dir=` and `manifest=`. Version 5
# resolves manifests exclusively through `environmentpath`: it looks for
# <environmentpath>/<environment>/manifests/*.pp. So instead of pointing at a
# single file, we build that directory layout in spec/fixtures and symlink the
# real manifest into it — the tests then run against the SAME file the host
# applies, with no copy to drift out of sync.

require 'rspec-puppet'
require 'rspec-puppet/coverage'
require 'fileutils'

REPO_ROOT    = File.expand_path(File.join(__dir__, '..')).freeze
FIXTURE_PATH = File.join(__dir__, 'fixtures').freeze
ENV_NAME     = 'production'.freeze

# Build <fixtures>/production/manifests/site.pp as a link to the real manifest.
env_manifests = File.join(FIXTURE_PATH, ENV_NAME, 'manifests')
FileUtils.mkdir_p(env_manifests)

real_manifest = File.join(REPO_ROOT, 'puppet', 'manifests', 'site.pp')
link_target   = File.join(env_manifests, 'site.pp')

FileUtils.rm_f(link_target)
begin
  FileUtils.ln_s(real_manifest, link_target)
rescue NotImplementedError, Errno::EPERM
  # Filesystems without symlink support: fall back to a copy.
  FileUtils.cp(real_manifest, link_target)
end

RSpec.configure do |c|
  c.environmentpath = FIXTURE_PATH
  c.environment     = ENV_NAME
  c.module_path     = File.join(FIXTURE_PATH, 'modules')

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
  c.after(:suite) do
    RSpec::Puppet::Coverage.report!(90)
  end
end
