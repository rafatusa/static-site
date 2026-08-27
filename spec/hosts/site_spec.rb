require 'spec_helper'

# Unit tests for puppet/manifests/site.pp.
#
# This is a SITE manifest (bare resource declarations, not a class), so the
# example group type is :host — rspec-puppet compiles the environment's
# manifests for a node and exposes the resulting catalog. `:type => :class`
# would not apply: there is no class to instantiate.
#
# `environment` is declared here as a `let`, NOT in RSpec.configure — it is a
# per-example setting in rspec-puppet 5 and setting it globally raises
# NoMethodError. See the API notes in spec/spec_helper.rb.
#
# Every example asserts on a resource the manifest actually declares. If a
# resource is renamed or removed these fail — which is the point.

describe 'static-site node', type: :host do
  let(:node)        { 'static-site.example.com' }
  let(:environment) { 'production' }

  # Compiling the manifest is itself the first assertion. An unknown variable
  # (the `$uri` heredoc bug) or a duplicate declaration ('/var/www/site' vs
  # '/var/www/site/') raises here, before any expectation runs.
  it 'compiles a valid catalog' do
    is_expected.to compile
  end

  describe 'nginx package' do
    it 'installs nginx' do
      is_expected.to contain_package('nginx').with_ensure('installed')
    end

    it 'refreshes the apt index before installing' do
      # Cloud images ship a prebuilt apt index old enough to name superseded
      # package versions; installing against it 404s. No cache_valid_time.
      is_expected.to contain_exec('apt-update')
        .with_command('/usr/bin/apt-get update')
        .that_comes_before('Package[nginx]')
    end

    it 'retries the apt refresh for flaky mirrors' do
      is_expected.to contain_exec('apt-update').with(
        'tries'     => 3,
        'try_sleep' => 10,
      )
    end
  end

  describe 'document root' do
    it 'declares the site root exactly once, without a trailing slash' do
      # REGRESSION: declaring both '/var/www/site' and '/var/www/site/' is a
      # duplicate declaration — Puppet normalises the trailing slash and aborts
      # the entire run before nginx is ever touched.
      is_expected.to contain_file('/var/www/site').with_ensure('directory')
    end

    it 'syncs content from the deploy directory' do
      is_expected.to contain_file('/var/www/site')
        .with_source('/tmp/udap-deploy/site')
        .with_recurse(true)
    end

    it 'purges files deleted from the repository' do
      # Without purge, a page removed from site/ in git lingers on the host
      # and stays publicly served.
      is_expected.to contain_file('/var/www/site').with(
        'purge' => true,
        'force' => true,
      )
    end

    it 'is owned by root' do
      is_expected.to contain_file('/var/www/site').with(
        'owner' => 'root',
        'group' => 'root',
      )
    end

    it 'restores the traverse bit on directories' do
      # REGRESSION: mode => '0644' applied recursively strips the execute bit
      # from the document root, so nginx cannot traverse into it and returns
      # 403 on EVERY request — after a configure stage that reported success.
      is_expected.to contain_exec('site-root-dir-perms')
        .with_command(%r{find /var/www/site -type d -exec chmod 0755})
        .with_refreshonly(true)
    end

    it 'reloads nginx when content changes' do
      is_expected.to contain_file('/var/www/site').that_notifies('Service[nginx]')
    end

    it 'waits for nginx to be installed before writing content' do
      is_expected.to contain_file('/var/www/site').that_requires('Package[nginx]')
    end
  end

  describe 'nginx vhost' do
    let(:vhost) { '/etc/nginx/sites-available/default' }

    it 'writes the vhost file' do
      is_expected.to contain_file(vhost).with(
        'ensure' => 'file',
        'owner'  => 'root',
        'mode'   => '0644',
      )
    end

    it 'points the document root at the site directory' do
      # Confirms ${site_root} interpolated as a Puppet variable.
      is_expected.to contain_file(vhost).with_content(%r{root /var/www/site;})
    end

    it 'passes nginx variables through literally, not as Puppet variables' do
      # REGRESSION — the bug that failed the first deploy.
      #
      # The heredoc tag must be @("VHOST"/$L). With only /L, `\$uri` is NOT
      # unescaped, Puppet parses `$uri` as a variable named 'uri', and
      # evaluation dies with "Unknown variable: 'uri'".
      #
      # If the escape switch regresses, compilation raises. If the backslash is
      # instead left in the output, nginx gets a broken `\$uri` directive and
      # fails its config test on the host. This asserts the exact literal text
      # nginx must receive.
      is_expected.to contain_file(vhost)
        .with_content(%r{try_files \$uri \$uri/ /index\.html;})
      is_expected.to contain_file(vhost).without_content(%r{\\\$uri})
    end

    it 'serves the health endpoint the verify stage depends on' do
      # The deploy's verify gate curls /health. If this block is removed the
      # deploy fails at the very last stage, after provisioning everything.
      is_expected.to contain_file(vhost).with_content(%r{location = /health})
      is_expected.to contain_file(vhost).with_content(%r{return 200})
    end

    it 'listens on port 80 as the default server' do
      is_expected.to contain_file(vhost).with_content(%r{listen 80 default_server;})
    end

    it 'does not enable directory listing' do
      # autoindex would expose the document root's file tree.
      is_expected.to contain_file(vhost).without_content(%r{autoindex\s+on})
    end

    it 'tests the config before reloading' do
      # Never reload a broken config: a bad vhost would take the site down
      # rather than fail the deploy.
      is_expected.to contain_file(vhost).that_notifies('Exec[nginx-config-test]')
      is_expected.to contain_exec('nginx-config-test')
        .with_command('/usr/sbin/nginx -t')
        .with_refreshonly(true)
        .that_notifies('Service[nginx]')
    end
  end

  describe 'nginx service' do
    it 'is running and enabled at boot' do
      is_expected.to contain_service('nginx').with(
        'ensure' => 'running',
        'enable' => true,
      )
    end

    it 'requires the package' do
      is_expected.to contain_service('nginx').that_requires('Package[nginx]')
    end
  end
end
