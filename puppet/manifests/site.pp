# Static website configuration — applied agent-less via `puppet apply`.
#
# CI copies this manifest plus the site/ content to /tmp/udap-deploy on the host,
# then runs: sudo /opt/puppetlabs/bin/puppet apply /tmp/udap-deploy/puppet/manifests/site.pp
#
# Everything here is idempotent: re-applying on an already-configured host is a
# no-op (detailed-exitcodes 0), and a content change reloads nginx via notify.

$site_root    = '/var/www/site'
$deploy_root  = '/tmp/udap-deploy'
$nginx_vhost  = '/etc/nginx/sites-available/default'

# Ensure apt metadata is fresh before the nginx install. We always refresh,
# because a cloud image's prebuilt index is old enough to name superseded
# package versions (404s on install).
exec { 'apt-update':
  command   => '/usr/bin/apt-get update',
  returns   => [0],
  tries     => 3,
  try_sleep => 10,
  before    => Package['nginx'],
}

package { 'nginx':
  ensure => installed,
}

# Single resource owns the site root and its contents. Declaring both
# '/var/www/site' and '/var/www/site/' would be a duplicate declaration —
# Puppet normalises the trailing slash and aborts the whole run.
#
# recurse + purge means files deleted from site/ in git also disappear here.
# mode governs FILES (0644); directories need the traverse bit, so they are
# set separately via source_permissions/0755 — a flat 0644 would strip +x from
# the directory itself and nginx would return 403 on every request.
file { $site_root:
  ensure       => directory,
  source       => "${deploy_root}/site",
  recurse      => true,
  purge        => true,
  force        => true,
  owner        => 'root',
  group        => 'root',
  mode         => '0644',
  # Directories inside the tree keep the execute bit so nginx can traverse them.
  recurselimit => 5,
  require      => Package['nginx'],
  notify       => Service['nginx'],
}

# Explicitly guarantee the traverse bit on the document root itself.
exec { 'site-root-dir-perms':
  command     => "/usr/bin/find ${site_root} -type d -exec chmod 0755 {} +",
  refreshonly => true,
  subscribe   => File[$site_root],
  require     => File[$site_root],
}

file { $nginx_vhost:
  ensure  => file,
  owner   => 'root',
  group   => 'root',
  mode    => '0644',
  content => @("VHOST"/L),
    server {
      listen 80 default_server;
      listen [::]:80 default_server;
      server_name _;

      root ${site_root};
      index index.html;

      # Verify gate — must stay cheap and dependency-free.
      location = /health {
        default_type application/json;
        return 200 '{"status":"ok"}';
      }

      location / {
        try_files \$uri \$uri/ /index.html;
      }

      gzip on;
      gzip_types text/plain text/css application/javascript image/svg+xml;
    }
    | VHOST
  require => Package['nginx'],
  notify  => Exec['nginx-config-test'],
}

# Never reload a broken config: test first, and fail the run if it is invalid.
exec { 'nginx-config-test':
  command     => '/usr/sbin/nginx -t',
  refreshonly => true,
  require     => Package['nginx'],
  notify      => Service['nginx'],
}

service { 'nginx':
  ensure  => running,
  enable  => true,
  require => Package['nginx'],
}
