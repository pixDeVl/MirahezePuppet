# class: role::db
class role::db (
    Optional[Array[String]] $daily_misc = lookup('role::db::daily_misc', {'default_value' => []}),
    Optional[Array[String]] $weekly_misc = lookup('role::db::weekly_misc', {'default_value' => []}),
    Optional[Array[String]] $fortnightly_misc = lookup('role::db::fornightly_misc', {'default_value' => []}),
    Optional[Array[String]] $monthly_misc = lookup('role::db::monthly_misc', {'default_value' => []}),
    Boolean $enable_bin_logs = lookup('role::db::enable_bin_logs', {'default_value' => true}),
    Boolean $enable_slow_log = lookup('role::db::enable_slow_log', {'default_value' => false}),
    Boolean $backup_sql = lookup('role::db::backup_sql', {'default_value' => true}),
    Boolean $enable_ssl = lookup('role::db::enable_ssl', {'default_value' => true}),
) {
    include mariadb::packages
    include prometheus::exporter::mariadb

    $mediawiki_password = lookup('passwords::db::mediawiki')
    $wikiadmin_password = lookup('passwords::db::wikiadmin')
    $matomo_password = lookup('passwords::db::matomo')
    $phorge_password = lookup('passwords::db::phorge')
    $exporter_password = lookup('passwords::db::exporter')
    $icinga_password = lookup('passwords::db::icinga')
    $icingaweb2_db_user_password = lookup('passwords::icingaweb2')
    $ido_db_user_password = lookup('passwords::icinga_ido')
    $reports_password = lookup('passwords::db::reports')

    ssl::wildcard { 'db wildcard': }

    file { '/etc/ssl/private':
        ensure => directory,
        owner  => 'root',
        group  => 'mysql',
        mode   => '0750',
    }

    class { 'mariadb::config':
        config          => 'mariadb/config/mw.cnf.erb',
        password        => lookup('passwords::db::root'),
        icinga_password => $icinga_password,
        enable_bin_logs => $enable_bin_logs,
        enable_ssl      => $enable_ssl,
        enable_slow_log => $enable_slow_log,
    }

    file { '/etc/mysql/wikitide/mediawiki-grants.sql':
        ensure  => present,
        content => template('mariadb/grants/mediawiki-grants.sql.erb'),
    }

    file { '/etc/mysql/wikitide/matomo-grants.sql':
        ensure  => present,
        content => template('mariadb/grants/matomo-grants.sql.erb'),
    }

    file { '/etc/mysql/wikitide/phorge-grants.sql':
        ensure  => present,
        content => template('mariadb/grants/phorge-grants.sql.erb'),
    }

    file { '/etc/mysql/wikitide/icinga2-grants.sql':
        ensure  => present,
        content => template('mariadb/grants/icinga2-grants.sql.erb'),
    }

    file { '/etc/mysql/wikitide/reports-grants.sql':
        ensure  => present,
        content => template('mariadb/grants/reports-grants.sql.erb'),
    }

    $firewall_rules_str = join(
        query_facts('Class[Role::Db] or Class[Role::Mediawiki] or Class[Role::Icinga2] or Class[Role::Phorge] or Class[Role::Matomo] or Class[Role::Reports]', ['networking'])
        .map |$key, $value| {
            if ( $value['networking']['interfaces']['ens19'] and $value['networking']['interfaces']['ens18'] ) {
                "${value['networking']['interfaces']['ens19']['ip']} ${value['networking']['interfaces']['ens18']['ip']} ${value['networking']['interfaces']['ens18']['ip6']}"
            } elsif ( $value['networking']['interfaces']['ens18'] ) {
                "${value['networking']['interfaces']['ens18']['ip']} ${value['networking']['interfaces']['ens18']['ip6']}"
            } else {
                "${value['networking']['ip']} ${value['networking']['ip6']}"
            }
        }
        .flatten()
        .unique()
        .sort(),
        ' '
    )
    ferm::service { 'mariadb':
        proto   => 'tcp',
        port    => '3306',
        srange  => "(${firewall_rules_str})",
        notrack => true,
    }

    # Create a user to allow db transfers between servers
    users::user { 'dbcopy':
        ensure   => present,
        uid      => 3000,
        ssh_keys => [
            'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOL4FH2aRAwbSGP1HLmo1YzaXRci2YnkTGJvT2E6Ay0d dbcopy@db101'
        ],
    }

    # Backup provisioning
    file { '/srv/backups':
        ensure => directory,
    }

    system::role { 'db':
        description => 'MySQL database server',
    }

    if $backup_sql {
        cron { 'backups-sql':
            ensure   => present,
            command  => '/usr/local/bin/wikitide-backup backup sql > /var/log/sql-backup.log 2>&1',
            user     => 'root',
            minute   => '0',
            hour     => '3',
            monthday => [fqdn_rand(13, 'db-backups') + 1, fqdn_rand(13, 'db-backups') + 15],
        }

        monitoring::nrpe { 'Backups SQL':
            command  => '/usr/lib/nagios/plugins/check_file_age -w 864000 -c 1209600 -f /var/log/sql-backup.log',
            docs     => 'https://meta.miraheze.org/wiki/Backups#General_backup_Schedules',
            critical => true
        }
    }

    $daily_misc.each |String $db| {
        cron { "backups-${db}":
            ensure  => present,
            command => "/usr/local/bin/wikitide-backup backup sql --database=${db} > /var/log/sql-${db}-backup-daily.log 2>&1",
            user    => 'root',
            special => 'daily',
        }

        monitoring::nrpe { "Backups SQL ${db}":
            command  => "/usr/lib/nagios/plugins/check_file_age -w 129600 -c 172800 -f /var/log/sql-${db}-backup-daily.log",
            docs     => 'https://meta.miraheze.org/wiki/Backups#General_backup_Schedules',
            critical => true
        }
    }

    $weekly_misc.each |String $db| {
        cron { "backups-${db}":
            ensure  => present,
            command => "/usr/local/bin/wikitide-backup backup sql --database=${db} > /var/log/sql-${db}-backup-weekly.log 2>&1",
            user    => 'root',
            minute  => '0',
            hour    => '5',
            weekday => '0',
        }

        monitoring::nrpe { "Backups SQL ${db}":
            command  => "/usr/lib/nagios/plugins/check_file_age -w 864000 -c 1209600 -f /var/log/sql-${db}-backup-weekly.log",
            docs     => 'https://meta.miraheze.org/wiki/Backups#General_backup_Schedules',
            critical => true
        }
    }

    $fortnightly_misc.each |String $db| {
        cron { "backups-${db}":
            ensure   => present,
            command  => "/usr/local/bin/wikitide-backup backup sql --database=${db} > /var/log/sql-${db}-backup-fortnightly.log 2>&1",
            user     => 'root',
            minute   => '0',
            hour     => '5',
            monthday => ['1', '15'],
        }

        monitoring::nrpe { "Backups SQL ${db}":
            command  => "/usr/lib/nagios/plugins/check_file_age -w 1555200 -c 1814400 -f /var/log/sql-${db}-backup-fortnightly.log",
            docs     => 'https://meta.miraheze.org/wiki/Backups#General_backup_Schedules',
            critical => true
        }
    }

    $monthly_misc.each |String $db| {
        cron { "backups-${db}":
            ensure   => present,
            command  => "/usr/local/bin/wikitide-backup backup sql --database=${db} > /var/log/sql-${db}-backup-monthly.log 2>&1",
            user     => 'root',
            minute   => '0',
            hour     => '5',
            monthday => ['24'],
        }

        monitoring::nrpe { "Backups SQL ${db}":
            command  => "/usr/lib/nagios/plugins/check_file_age -w 3024000 -c 3456000 -f /var/log/sql-${db}-backup-monthly.log",
            docs     => 'https://meta.miraheze.org/wiki/Backups#General_backup_Schedules',
            critical => true
        }
    }
}
