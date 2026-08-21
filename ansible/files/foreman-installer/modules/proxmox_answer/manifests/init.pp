# Managed by this POC through satellite-installer custom Hiera.
class proxmox_answer {
  file { '/etc/httpd/conf.d/04-proxmox-answer.conf':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => "# Managed by satellite-test custom Hiera.\nProxyPass /proxmox-answer unix:/run/proxmox-foreman-answer/answer.sock|http://localhost/\n",
    notify  => Service['httpd'],
  }
}
