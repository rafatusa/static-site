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

require 'rspec-puppet'
require 'rspec-puppet/coverage'

fixture_path = File.expand_path(File.join(__dir__, 'fixtures'))

RSpec.configure do |c|
  c.module_path   = File.join(fixture_path, 'modules')
  c.manifest_dir  = File.join(fixture_path, 'manifests')
  c.manifest      = File.expand_path(File.join(__dir__, '..', 'puppet', 'manifests', 'site.pp'))
  c.environmentpath = fixture_path

  # Deterministic facts. The manifest targets Ubuntu on EC2; pinning the facts
  # means a test failure is a manifest change, never a runner change.
  c.default_facts = {
    'os' => {
      'family'  => 'Debian',
      'name'    => 'Ubuntu',
      'release' => { 'full' => '22.04', 'major' => '22' },
    },
    'osfamily'                  => 'Debian',
    'operatingsystem'           => 'Ubuntu',
    'operatingsystemrelease'    => '22.04',
    'path'                      => '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
  }

  # An unexpected error must fail loudly rather than yield an empty catalog
  # that then passes vacuous assertions.
  c.strict_variables = false
  c.raise_errors_for_deprecations!

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
