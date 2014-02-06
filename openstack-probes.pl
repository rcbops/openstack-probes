#!$NIM_BIN/perl

use strict;
use Getopt::Std;
use Nimbus::API;
use Nimbus::Session;
use Nimbus::CFG;
use Data::Dumper;
$| = 1;

my $prgname = 'openstack-probes';
my $version = '0.11';
my $sub_sys = '1.1.1';
my $config;
my %options;

sub suppression_active {
    my ($_sec, $_min, $_hour) = localtime();
    my $current_min = ($_hour * 60) + $_min;
    my $_supp = $config->{'suppression'};
    foreach my $_interval_name (keys(%{$config->{'suppression'}})) {
        my $interval = $config->{'suppression'}->{$_interval_name};
        next if (($interval->{'active'} =~ /no/i) || ($interval->{'active'} !~ /yes/i)); 
        my ($_st_hour, $_st_min) = $interval->{'start'} =~ /(\d+):(\d+)/;
        my ($_end_hour, $_end_min) = $interval->{'end'} =~ /(\d+):(\d+)/;
        if (!defined($_st_hour) || !defined($_st_min) ||
            !defined($_end_hour) || !defined($_end_min)) {
            nimLog(1, "Invalid format in suppression interval '$_interval_name'");
            next;
        }
        my $start_mins = ($_st_hour * 60) + $_st_min;
        my $end_mins = ($_end_hour * 60) + $_end_min;
        if (($current_min >= $start_mins) && ($current_min < $end_mins)) {
            return $_interval_name;
        }
    }
    return undef;    
}

sub checkRabbit {
    my @data;
    if ( -e '/etc/init.d/rabbitmq-server' ) {
        nimLog(1, "RabbitMQ detected. Checking status...");
        @data = `$config->{'setup'}->{'rabbitmq_cmd_line'} list_queues 2>/dev/null`;
        if ($? != 0 || !@data) {
            nimLog(1, "RabbitMQ not reachable....Is the service running?");
            $config->{'status'}->{'rabbit'}->{'samples'}++;
            if ($config->{'status'}->{'rabbit'}->{'samples'} >= $config->{'setup'}->{'samples'}) {
                if ($config->{'status'}->{'rabbit'}->{'triggered'} == 0){
                    nimLog(1, "RabbitMQ not reachable....Max attempts reached. Creating an alert!");
                    nimAlarm( $config->{'messages'}->{'RabbitConnection'}->{'level'},$config->{'messages'}->{'RabbitConnection'}->{'text'},$sub_sys,nimSuppToStr(0,0,0,"rabbitconnect"));
                    $config->{'status'}->{'rabbit'}->{'triggered'} = 1;
                }
            }
            return;
        } else {
            if ($config->{'status'}->{'rabbit'}-{'triggered'} == 1){
                $config->{'status'}->{'rabbit'}->{'samples'} = 0;
                nimLog(1, "RabbitMQ Responded!!");
                nimAlarm( NIML_CLEAR, 'RabbitMQ connection established',$sub_sys,nimSuppToStr(0,0,0,"rabbitconnect"));
            }
        }
        nimLog(1, 'Returned '.scalar(@data).' lines from rabbitmqctl');
        my $queues_list = {};
        foreach my $line (@data) {
            my ($key, $value) = $line =~ /(?:^|\s+)(\S+)\s*\t\s*("[^"]*"|\S*)/;
            next if (!defined($key) || !defined($value));
            next if ($key == "notifications.info" || $key =~ /glance/);
            $queues_list->{$key} = $value;
        }
        while ( my ($key, $value) = each(%$queues_list) ) {
            if ( $value >= $config->{'setup'}->{'rabbit-WARN'}) {
                if (!defined($config->{'status'}->{$key}->{'samples'})){$config->{'status'}->{$key}->{'samples'} = 0;};
                $config->{'status'}->{$key}->{'samples'}++;
                $config->{'status'}->{$key}->{'last'} = $value;
                if ($config->{'status'}->{$key}->{'samples'} >= $config->{'setup'}->{'samples'}) {
                    if ($value >= $config->{'setup'}->{'rabbit-CRIT'}) {
                        if ($config->{'status'}->{'rabbit'}->{'crit-triggered'} == 0){
                            nimLog(1, "Critical alert on message queue $key with queue length $value");
                            my $alert_string = "[CRITICAL] RabbitMQ queue $key is not processing. Queue $key has $value messages pending.";
                            nimAlarm( 5,$alert_string,$sub_sys,nimSuppToStr(0,0,0,"rabbitqueue"));
                            $config->{'status'}->{'rabbit'}->{'crit-triggered'} = 1;
                        }
                    } else {
                        if ($config->{'status'}->{'rabbit'}->{'warn-triggered'} == 0){
                            nimLog(1, "Warning alert on message queue $key with queue length $value");
                            my $alert_string = "[WARNING] RabbitMQ queue $key is not processing. Queue $key has $value messages pending.";
                            nimAlarm( 4,$alert_string,$sub_sys,nimSuppToStr(0,0,0,"rabbitqueue"));
                            $config->{'status'}->{'rabbit'}->{'warn-triggered'} = 1;
                        }
                    }
                }
            } else {
                if ($config->{'status'}->{'rabbit'}->{'warn-triggered'} == 1 || $config->{'status'}->{'rabbit'}->{'crit-triggered'} == 1){
                    $config->{'status'}->{$key}->{'samples'} = 0;
                    $config->{'status'}->{'rabbit'}->{'warn-triggered'} = 0;
                    $config->{'status'}->{'rabbit'}->{'crit-triggered'} = 0;
                    $config->{'status'}->{$key}->{'last'} = $value;
                    nimLog(1, "Checking RabbitMQ queue $key queue length now $value");
                    my $alert_string = "RabbitMQ alert on queue $key has cleared";
                    nimAlarm( NIML_CLEAR,$alert_string,$sub_sys,nimSuppToStr(0,0,0,"rabbitqueue"));
                }
            }
        }
    } else {
        nimLog(1, "RabbitMQ NOT detected. Skipping.");
    }
}

sub checkNova {
    my @data;
    if ( -e '/usr/bin/nova-manage' ) {
        nimLog(1, "Nova-Manage detected. Checking status...");
        @data = `/usr/bin/nova-manage service list 2>/dev/null`;
        my $host = `hostname`;
        chomp($host);
        if ($? != 0 || !@data) {
            nimLog(1, "Something is wrong!!! Nova-manage did not respond correctly.");
            $config->{'status'}->{'nova'}->{'samples'}++;
            if ($config->{'status'}->{'nova'}->{'samples'} >= $config->{'setup'}->{'samples'}) {
                if ($config->{'status'}->{'nova'}->{'triggered'} == 0){
                    nimLog(1, "Nova-manage not responding....Max attempts reached. Creating an alert!");
                    nimAlarm( $config->{'messages'}->{'NovaConnection'}->{'level'},$config->{'messages'}->{'NovaConnection'}->{'text'},$sub_sys,nimSuppToStr(0,0,0,"novaconnect"));
                    $config->{'status'}->{'nova'}->{'triggered'} = 1;
                }
            }
            return;
        } else {
            $config->{'status'}->{'nova'}->{'samples'} = 0;
            if ($config->{'status'}->{'nova'}->{'triggered'} == 1){
                nimLog(1, "Nova-manage Responded!!");
                nimAlarm( NIML_CLEAR, 'Nova-manage has started responding',$sub_sys,nimSuppToStr(0,0,0,"novaconnect"));
                $config->{'status'}->{'nova'}->{'triggered'} = 0;
            }
        }
        nimLog(1, 'Returned '.scalar(@data).' lines from nova-manage');
        my $service_list = {};
        shift @data;
        foreach my $line (@data) {
            my @values = split(' ',$line);
            if ((@values[1] eq $host) and (@values[3] eq 'enabled')){
                $service_list->{$values[0]} = $values[4];
            }
        }
        while ( my ($key, $value) = each(%$service_list) ) {
            if ( $value eq 'XXX' ) {
                if (!defined($config->{'status'}->{$key}->{'samples'})){$config->{'status'}->{$key}->{'samples'} = 0;};
                $config->{'status'}->{$key}->{'samples'}++;
                if ($config->{'status'}->{$key}->{'samples'} >= $config->{'setup'}->{'samples'}) {
                    if ($config->{'status'}->{'nova'}->{'triggered'} == 0){
                        nimLog(1, "Critical alert on nova service $key");
                        my $alert_string = "[CRITICAL] Nova Service $key is not checking in. Please investigate.";
                        nimAlarm( 5,$alert_string,$sub_sys,nimSuppToStr(0,0,0,"novaservice"));
                        $config->{'status'}->{'nova'}->{'triggered'} = 1;
                    }
                }
            } else {
                $config->{'status'}->{$key}->{'samples'} = 0;
                if ($config->{'status'}->{'nova'}->{'triggered'} == 1){
                    nimLog(1, "Nova service $key has checked in.");
                    my $alert_string = "Nova Service ($key) Alert clear";
                    nimAlarm( NIML_CLEAR,$alert_string,$sub_sys,nimSuppToStr(0,0,0,"novaservice"));
                    $config->{'status'}->{'nova'}->{'triggered'} = 0;
               }
            }
        }
    } else {
        nimLog(1, "Nova-Manage NOT detected. Skipping.");
    }
}

sub checkKeystone {
    my @data;
    if (-e '/usr/bin/keystone-all' ){
        nimLog(1, "Keystone detected. Checking status...");
        @data = `/usr/bin/keystone --os-username $config->{'setup'}->{'os-username'} --os-tenant-name $config->{'setup'}->{'os-tenant'} --os-auth-url $config->{'setup'}->{'os-auth-url'} --os-password $config->{'setup'}->{'os-password'} token-get 2>/dev/null`;
        if ($? != 0 || !@data) {
            nimLog(1, "Something is wrong!!! Keystone did not respond correctly.");
            $config->{'status'}->{'keystone'}->{'samples'}++;
            if ($config->{'status'}->{'keystone'}->{'samples'} >= $config->{'setup'}->{'samples'}) {
                if ($config->{'status'}->{'keystone'}->{'triggered'} == 0){
                    nimLog(1, "Keystone not responding....Max attempts reached. Creating an alert!");
                    nimAlarm( $config->{'messages'}->{'KeystoneConnection'}->{'level'},$config->{'messages'}->{'KeystoneConnection'}->{'text'},$sub_sys,nimSuppToStr(0,0,0,"keystoneconnect"));
                    $config->{'status'}->{'keystone'}->{'triggered'} = 1;
                }
            }
            return;
        } else {
            $config->{'status'}->{'keystone'}->{'samples'} = 0;
            if ($config->{'status'}->{'keystone'}->{'triggered'} == 1){
                nimLog(1, "Keystone Responded!!");
                nimAlarm( NIML_CLEAR, 'Keystone has started responding',$sub_sys,nimSuppToStr(0,0,0,"keystoneconnect"));
                $config->{'status'}->{'keystone'}->{'triggered'} = 0;
            }
        } 
    }
}

sub checkGlance {
    my @data;
    if (-e '/usr/bin/glance-manage' ){
        nimLog(1, "Glance detected. Checking status...");
        @data = `/usr/bin/glance --os-username $config->{'setup'}->{'os-username'} --os-tenant-name $config->{'setup'}->{'os-tenant'} --os-auth-url $config->{'setup'}->{'os-auth-url'} --os-password $config->{'setup'}->{'os-password'} index 2>/dev/null`;
        if ($? != 0 || !@data) {
            nimLog(1, "Something is wrong!!! Glance did not respond correctly.");
            $config->{'status'}->{'glance'}->{'samples'}++;
            if ($config->{'status'}->{'glance'}->{'samples'} >= $config->{'setup'}->{'samples'}) {
                if ($config->{'status'}->{'glance'}->{'triggered'} == 0){
                    nimLog(1, "Glance not responding....Max attempts reached. Creating an alert!");
                    nimAlarm( $config->{'messages'}->{'GlanceConnection'}->{'level'},$config->{'messages'}->{'GlanceConnection'}->{'text'},$sub_sys,nimSuppToStr(0,0,0,"glanceconnect"));
                    $config->{'status'}->{'glance'}->{'triggered'} = 1;
                }
            }
            return;
        } else {
            $config->{'status'}->{'glance'}->{'samples'} = 0;
            if ($config->{'status'}->{'glance'}->{'triggered'} == 1){
                nimLog(1, "Glance Responded!!");
                nimAlarm( NIML_CLEAR, 'Glance has started responding',$sub_sys,nimSuppToStr(0,0,0,"glanceconnect"));
                $config->{'status'}->{'glance'}->{'triggered'} = 0;
            }
        } 
    }
}

sub checkNeutron {
    my @data;
    if ( -e '/etc/neutron' || -e '/etc/quantum' ) {
        nimLog(1, "Neutron/Quantum detected. Checking status...");
	   if ( -e '/usr/bin/neutron' ) {
         	@data = `/usr/bin/neutron --os-username $config->{'setup'}->{'os-username'} --os-tenant-name $config->{'setup'}->{'os-tenant'} --os-auth-url $config->{'setup'}->{'os-auth-url'} --os-password $config->{'setup'}->{'os-password'} agent-list 2>/dev/null`;
	   } else {
        	@data = `/usr/bin/quantum --os-username $config->{'setup'}->{'os-username'} --os-tenant-name $config->{'setup'}->{'os-tenant'} --os-auth-url $config->{'setup'}->{'os-auth-url'} --os-password $config->{'setup'}->{'os-password'} agent-list 2>/dev/null`;
    	}
        my $host = `hostname`;
        chomp($host);
        if ($? != 0 || !@data) {
            nimLog(1, "Something is wrong!!! Neutron/Quantum did not respond correctly.");
            $config->{'status'}->{'neutron'}->{'samples'}++;
            if ($config->{'status'}->{'neutron'}->{'samples'} >= $config->{'setup'}->{'samples'}) {
                if ($config->{'status'}->{'neutron'}->{'triggered'} == 0){
                    nimLog(1, "Neutron/Quantum not responding....Max attempts reached. Creating an alert!");
                    nimAlarm( $config->{'messages'}->{'NeutronConnection'}->{'level'},$config->{'messages'}->{'NeutronConnection'}->{'text'},$sub_sys,nimSuppToStr(0,0,0,"neutronconnect"));
                    $config->{'status'}->{'neutron'}->{'triggered'} = 1;
                }
            }
            return;
        } else {
            $config->{'status'}->{'neutron'}->{'samples'} = 0;
            if ($config->{'status'}->{'neutron'}->{'triggered'} == 1){
                nimLog(1, "Neutron Responded!!");
                nimAlarm( NIML_CLEAR, 'Neutron/Quantum has started responding',$sub_sys,nimSuppToStr(0,0,0,"neutronconnect"));
                $config->{'status'}->{'neutron'}->{'triggered'} = 0;
            }
        }
        nimLog(1, 'Returned '.scalar(@data).' lines from neutron/Quantum');
        my $service_list = {};
        shift @data;
        foreach my $line (@data) {
            my @values = split(' ',$line);
            if ((@values[2] =~ /$host/) and (@values[3] eq 'True')){
                $service_list->{$values[1]} = $values[3];
            }
        }
        while ( my ($key, $value) = each(%$service_list) ) {
            if ( $value eq 'XXX' || $value eq 'xxx' ) {
                if (!defined($config->{'status'}->{$key}->{'samples'})){$config->{'status'}->{$key}->{'samples'} = 0;};
                $config->{'status'}->{$key}->{'samples'}++;
                if ($config->{'status'}->{$key}->{'samples'} >= $config->{'setup'}->{'samples'}) {
                    if ($config->{'status'}->{'neutron'}->{'triggered'} == 0){
                        nimLog(1, "Critical alert on neutron service $key");
                        my $alert_string = "[CRITICAL] Neutron/Quantum Service $key is not checking in. Please investigate.";
                        nimAlarm( 5,$alert_string,$sub_sys,nimSuppToStr(0,0,0,"neutronservice"));
                        $config->{'status'}->{'neutron'}->{'triggered'} = 1;
                    }
                }
            } else {
                $config->{'status'}->{$key}->{'samples'} = 0;
                if ($config->{'status'}->{'neutron'}->{'triggered'} == 1){
                    nimLog(1, "Neutron/Quantum service $key has checked in.");
                    my $alert_string = "Neutron Service ($key) Alert clear";
                    nimAlarm( NIML_CLEAR,$alert_string,$sub_sys,nimSuppToStr(0,0,0,"neutronservice"));
                    $config->{'status'}->{'neutron'}->{'triggered'} = 0;
               }
            }
        }
    } else {
        nimLog(1, "Neutron/Quantum NOT detected. Skipping.");
    }
}

sub checkCinder {
    my @vgcheck = `$config->{'setup'}->{'lvm-cmd-line'} $config->{'setup'}->{'volume-name'} 2>/dev/null`;
    if ($? == 0 ) {
        nimLog(1, "Cinder volume detected. Checking status...");
        my $vgSize = `vgs -o size --noheadings --units t $config->{'setup'}->{'volume-name'} 2>/dev/null`;
        my $vgFree = `vgs -o free --noheadings --units t $config->{'setup'}->{'volume-name'} 2>/dev/null`;
        my $alarm = ($vgSize/100)*$config->{'setup'}->{'volume-alarm'};
        if ( $vgFree < $alarm ) {
            if (!defined($config->{'status'}->{'volumeGroup'}->{'samples'})){$config->{'status'}->{'volumeGroup'}->{'samples'} = 0;};
            $config->{'status'}->{'volumeGroup'}->{'samples'}++;
            if ($config->{'status'}->{'volumeGroup'}->{'samples'} >= $config->{'setup'}->{'samples'}) {
                if ($config->{'status'}->{'volumeGroup'}->{'triggered'} == 0){
                    my $alert_string = "Warning Volume Group $config->{'setup'}->{'volume-name'} size is under $config->{'setup'}->{'volume-alarm'}\% of $vgSize";
                    nimLog(1, $alert_string);
                    nimAlarm( 5,$alert_string,$sub_sys,nimSuppToStr(0,0,0,"cindervolume"));
                    $config->{'status'}->{'volumeGroup'}->{'triggered'} = 1;
                }
            } else {
                $config->{'status'}->{'volumeGroup'}->{'samples'} = 0;
                if ($config->{'status'}->{'volumeGroup'}->{'triggered'} == 1){
                    my $alert_string = "Volume Group alert has cleared";
                    nimLog(1, $alert_string);
                    nimAlarm( NIML_CLEAR,$alert_string,$sub_sys,nimSuppToStr(0,0,0,"cindervolume"));
                    $config->{'status'}->{'volumeGroup'}->{'triggered'} = 0;
                }
           }     
        }
    } else {
        nimLog(1, "Cinder volume NOT detected. Skipping.");
    }
}

sub checkKvm {
    my @data;
    if (-e '/usr/bin/virsh' ){
        nimLog(1, "LibVirt detected. Checking status...");
        @data = `/usr/bin/virsh sysinfo 2>/dev/null`;
        if ($? != 0 || !@data) {
            nimLog(1, "Something is wrong!!! LibVirt did not respond correctly.");
            $config->{'status'}->{'kvm'}->{'samples'}++;
            if ($config->{'status'}->{'kvm'}->{'samples'} >= $config->{'setup'}->{'samples'}) {
                if ($config->{'status'}->{'kvm'}->{'triggered'} == 0){
                    nimLog(1, "LibVirt not responding....Max attempts reached. Creating an alert!");
                    nimAlarm( $config->{'messages'}->{'KvmConnection'}->{'level'},$config->{'messages'}->{'KvmConnection'}->{'text'},$sub_sys,nimSuppToStr(0,0,0,"kvmconnect"));
                    $config->{'status'}->{'kvm'}->{'triggered'} = 1;
                }
            }
            return;
        } else {
            $config->{'status'}->{'kvm'}->{'samples'} = 0;
            if ($config->{'status'}->{'kvm'}->{'triggered'} == 1){
                nimLog(1, "LibVirt Responded!!");
                nimAlarm( NIML_CLEAR, 'LibVirt has started responding',$sub_sys,nimSuppToStr(0,0,0,"kvmconnect"));
                $config->{'status'}->{'kvm'}->{'triggered'} = 0;
            }
        } 
    }
}

sub timeout {
    my $timestamp = time();
    if ($timestamp < $config->{'status'}->{'next_run'}) { return; }
    $config->{'status'}->{'next_run'} += $config->{'setup'}->{'interval'};
    nimLog(1, "($config->{'status'}->{'next_run'}) interval expired - running");
    my $_s_active = suppression_active();
    if (defined($_s_active)) {
        nimLog(1, "Suppression interval '$_s_active' active");
        return;
    }
    checkRabbit();
    checkMysql();
    checkNova();
    checkNeutron();
    checkCinder();
    checkKeystone();
    checkGlance();
    checkKvm();
}

sub checkMysql {
    if ( -e '/etc/init.d/mysql' || -e '/etc/init.d/mysqld' ) {
        nimLog(1, "Mysql detected. Checking status...");
        my $_exec = initialize_mysql_exec();
        if (!defined($_exec)) {
            nimLog(0, "Execution or authentication error - cannot perform replication query");
            return;
        }
        if (!defined($config->{'setup'}->{'mysql_cmd_line'})) {
            nimLog(1, "Database connection error. Client not defined in config file.");
            nimAlarm( $config->{'messages'}->{'DatabaseConnection'}->{'level'},$config->{'messages'}->{'DatabaseConnection'}->{'text'},$sub_sys,nimSuppToStr(0,0,0,"mysqlcommand"));
            return;
        }
        my @data = `$config->{'setup'}->{'mysql_cmd_line'} 2>/dev/null`;
        if (!@data) {
            nimAlarm( $config->{'messages'}->{'DatabaseConnection'}->{'level'},$config->{'messages'}->{'DatabaseConnection'}->{'text'},$sub_sys,nimSuppToStr(0,0,0,"mysqlconnect"));
            nimLog(1,$config->{'messages'}->{'DatabaseConnection'}->{'text'});
            return;
        } else {
            nimLog(1, "Connecting to database.....Success!");
            nimAlarm( NIML_CLEAR,'Database connection established',$sub_sys,nimSuppToStr(0,0,0,"mysqlconnect"));
        }
        nimLog(1, 'Returned '.scalar(@data).' lines from mysql query');
        my $slave_status = {};
        foreach my $line (@data) {
            my ($key, $value) = $line =~ /^\s*(\S+):\s(\S*)$/;
            next if (!defined($key) || !defined($value));
            $slave_status->{$key} = $value;
        }
        if ($slave_status->{'Slave_IO_Running'} =~ /no/i) {
            $config->{'status'}->{'Slave_IO_Running'}->{'samples'}++;
            $config->{'status'}->{'Slave_IO_Running'}->{'last'} = $slave_status->{'Slave_IO_Running'};
            if ($config->{'status'}->{'Slave_IO_Running'} >= $config->{'samples'}) {
                nimLog(1, "Alerting Slave_IO_Running status");
                nimAlarm( $config->{'messages'}->{'Slave_IO_Running'}->{'level'},
                    $config->{'messages'}->{'Slave_IO_Running'}->{'text'}." ($config->{'status'}->{'Slave_IO_Running'}->{'samples'} samples) ",$sub_sys,nimSuppToStr(0,0,0,"mysqlslaveio"));
            }

        } elsif ($slave_status->{'Slave_IO_Running'} =~ /yes/i) {
            nimLog(1, 'Slave_IO_Running status....running');
            $config->{'status'}->{'Slave_IO_Running'}->{'samples'} = 0;
            $config->{'status'}->{'Slave_IO_Running'}->{'last'} = $slave_status->{'Slave_IO_Running'};
            nimAlarm( NIML_CLEAR, 'Slave_IO_Running confirmed', $sub_sys,nimSuppToStr(0,0,0,"mysqlslaveio"));
        } else {
            nimLog(1, "Invalid value detected in 'Slave_IO_Running' : ($slave_status->{'Slave_IO_Running'})");
        }
        if ($slave_status->{'Slave_SQL_Running'} =~ /no/i) {
            $config->{'status'}->{'Slave_SQL_Running'}->{'samples'}++;
            $config->{'status'}->{'Slave_SQL_Running'}->{'last'} = $slave_status->{'Slave_SQL_Running'};
            if ($config->{'status'}->{'Slave_SQL_Running'} >= $config->{'samples'}) {
                nimLog(1, "Alerting Slave_SQL_Running status");
                nimAlarm( $config->{'messages'}->{'Slave_SQL_Running'}->{'level'},
                    $config->{'messages'}->{'Slave_SQL_Running'}->{'text'}." ($config->{'status'}->{'Slave_SQL_Running'}->{'samples'} samples) ",$sub_sys,nimSuppToStr(0,0,0,"mysqlslavesql"));
            }
        } elsif ($slave_status->{'Slave_SQL_Running'} =~ /yes/i) {
            nimLog(1, 'Slave_SQL_Running status....running');
            $config->{'status'}->{'Slave_SQL_Running'}->{'samples'} = 0;
            $config->{'status'}->{'Slave_SQL_Running'}->{'last'} = $slave_status->{'Slave_SQL_Running'};
            nimAlarm( NIML_CLEAR, "Slave_SQL_Running is running", $sub_sys,nimSuppToStr(0,0,0,"mysqlslavesql"));
        } else {
            nimLog(1, "Invalid value detected in 'Slave_SQL_Running' : ($slave_status->{'Slave_SQL_Running'})");
        }
        if ($slave_status->{'Seconds_Behind_Master'} >= $config->{'setup'}->{'mysql-WARN'} || $slave_status->{'Seconds_Behind_Master'} eq 'NULL') {
            $config->{'status'}->{'Seconds_Behind_Master'}->{'samples'}++;
            $config->{'status'}->{'Seconds_Behind_Master'}->{'last'} = $slave_status->{'Seconds_Behind_Master'};
            if ($config->{'status'}->{'Seconds_Behind_Master'}->{'samples'} >= $config->{'setup'}->{'samples'}) {
                if ($slave_status->{'Seconds_Behind_Master'} >= $config->{'setup'}->{'mysql-CRIT'} || $slave_status->{'Seconds_Behind_Master'} eq 'NULL') {
                    nimLog(1, "Critical alert on 'Seconds_Behind_Master' ($slave_status->{'Seconds_Behind_Master'})");
                    my $alert_string = $config->{'messages'}->{'SecondBehindCrit'}->{'text'};
                    $alert_string =~ s/%SEC_BEHIND%/$slave_status->{'Seconds_Behind_Master'}/e;
                    $alert_string .= " ($config->{'status'}->{'Seconds_Behind_Master'}->{'samples'} samples)"; 
                    nimAlarm( $config->{'messages'}->{'SecondBehindCrit'}->{'level'},$alert_string,$sub_sys,nimSuppToStr(0,0,0,"mysqlsecbehind"));
                } else {
                    nimLog(1, "Warning alert on 'Seconds_Behind_Master' ($slave_status->{'Seconds_Behind_Master'})");
                    my $alert_string = $config->{'messages'}->{'SecondBehindWarn'}->{'text'};
                    $alert_string =~ s/%SEC_BEHIND%/$slave_status->{'Seconds_Behind_Master'}/e;
                    $alert_string .= " ($config->{'status'}->{'Seconds_Behind_Master'}->{'samples'} samples)";
                    nimAlarm( $config->{'messages'}->{'SecondBehindWarn'}->{'level'},$alert_string,$sub_sys,nimSuppToStr(0,0,0,"mysqlsecbehind"));
                }
            }
        } else {
            $config->{'status'}->{'Seconds_Behind_Master'}->{'samples'} = 0;
            $config->{'status'}->{'Seconds_Behind_Master'}->{'last'} = $slave_status->{'Seconds_Behind_Master'};
            nimLog(1, "Checking 'Seconds_Behind_Master' ($slave_status->{'Seconds_Behind_Master'})");
            my $alert_string = $config->{'messages'}->{'SecondBehindWarn'}->{'text'};
            $alert_string =~ s/%SEC_BEHIND%/$slave_status->{'Seconds_Behind_Master'}/e;
            $alert_string .= " ($config->{'status'}->{'Seconds_Behind_Master'}->{'samples'} samples)";
            nimAlarm( NIML_CLEAR, $alert_string, $sub_sys,nimSuppToStr(0,0,0,"mysqlsecbehind"));
        }
    } else {
        nimLog(1, "Mysql NOT detected. Skipping.");
        return;
    }
    return;
}

sub test_exec_line {
    my ($_exec_line) = @_;
    
    if (!defined($_exec_line)) {
        return undef;
    }

    nimLog(1, "exec_line : ".$_exec_line);
    # the exec lines should be 0 for successful query - 1 for auth failure,
    # -1 for unspecific failures, and ($? >> 8) gives the code for other 
    # failures.
    my @_results = `$_exec_line`;
    if ($? != 0) {
        my $err_code = ($? >> 8);
        nimLog(1, "Exec failure ($err_code)");
        return $err_code;
    }

    # auth failures should be caught above, but check for empty results
    # anyway...
    if (!@_results) {
        return 1;
    }

    foreach my $line (@_results) {
        if ($line =~ "Slave_IO") {
            nimLog(1, "mysql query succeeded");
            return 0;
        }
    }
    return 1;
}

# Determine the mysql execution syntax
#
# - this works by taking the available auth/parms until we find a combo
#   that completes successfully.  Finish on first success.
#
sub initialize_mysql_exec {

    if (!defined($config->{'setup'}->{'mysql_exec'}) || ($config->{'setup'}->{'mysql_exec'} eq '')) {
        my @_exec;
        chomp(@_exec = `which mysql 2>/dev/null `);
        if (!@_exec) {
            nimLog(1, 'Cannot locate the executable mysql');
            nimAlarm( $config->{'messages'}->{'MysqlClient'}->{'level'}, $config->{'messages'}->{'MysqlClient'}->{'text'},$sub_sys,nimSuppToStr(0,0,0,"mysqlcli"));
            $config->{'setup'}->{'mysql_exec'} = undef;
            return undef;
        } else {
            my $_exec_path = $_exec[0];
            nimLog(1, "Located mysql executable: '$_exec_path'");
            $config->{'setup'}->{'mysql_exec'} = $_exec_path;
            nimAlarm( NIML_CLEAR, $config->{'messages'}->{'MysqlClient'}->{'text'},$sub_sys,nimSuppToStr(0,0,0,"mysqlcli"));
        }
    }
    my $_query = ' -E -e "SHOW SLAVE STATUS"';
    my %_params = (
        '1default'  => (defined($config->{'setup'}->{'mysql_defaults_file'}) && ($config->{'setup'}->{'mysql_defaults_file'} ne '')) ? "--defaults-file=$config->{'setup'}->{'mysql_defaults_file'}" : undef,
        '2username' => (defined($config->{'setup'}->{'username'})            && ($config->{'setup'}->{'username'} ne ''))            ? "-u $config->{'setup'}->{'username'}" : undef,
        '3password' => (defined($config->{'setup'}->{'password'})            && ($config->{'setup'}->{'password'} ne ''))            ? "-p$config->{'setup'}->{'password'}"  : undef,
        '4hostname' => (defined($config->{'setup'}->{'hostname'})            && ($config->{'setup'}->{'hostname'} ne ''))            ? "-h $config->{'setup'}->{'hostname'}" : undef,
        '5port'     => (defined($config->{'setup'}->{'port'})                && ($config->{'setup'}->{'port'} ne ''))                ? "-P $config->{'setup'}->{'port'}"     : undef
    );
    
    foreach my $key (keys(%_params)) {
        if (!defined($_params{$key})) {
            delete($_params{$key});
        }
    }
    
    my $loops = 2**(scalar(keys(%_params)));
    for (my $i = 0; $i < $loops; $i++) {
        nimLog(1, "exec iteration $i");
        my $cmd_line = "$config->{'setup'}->{'mysql_exec'}";

        my $shift = 0;
        foreach my $key (sort keys(%_params)) {
            if ((1 << $shift) & $i) {
                if (defined($_params{$key}) && ($_params{$key} ne '')) { # redundant, but it's best to check - we can probably get rid of this
                    $cmd_line .= " $_params{$key}";
                }
            }
            $shift++;
        }
        $cmd_line .= $_query;
        if (test_exec_line($cmd_line) == 0) {
            $config->{'setup'}->{'mysql_cmd_line'} = $cmd_line;
            return 1;
        }        
    }
    return undef;
}

sub readConfig {
    nimLog(1, "'$prgname' : Reading Config File");
    $config       = Nimbus::CFG->new("$prgname.cfg");    
    my $loglevel  = $options{'d'} || $config->{'setup'}->{'loglevel'} || 0;
    my $logfile   = $options{'l'} || $config->{'setup'}->{'logfile'} || $prgname.'.log';
    nimLogSet($logfile, $prgname, $loglevel, 0);
    if ( -e '/root/openrc' ) {
	open (openrc,'/root/openrc');
	while (<openrc>) {
		chomp;
		if (substr($_,0,1) !~ "#"){
			my ($key, $val) = split /=/;
			if ($key =~ "OS_USERNAME") { if (length($config->{'setup'}->{'os-username'}) eq 0) { $config->{'setup'}->{'os-username'} = $val; }}
			if ($key =~ "OS_PASSWORD") { if (length($config->{'setup'}->{'os-password'}) eq 0) { $config->{'setup'}->{'os-password'} = $val; }}
			if ($key =~ "OS_TENANT_NAME") { if (length($config->{'setup'}->{'os-tenant'}) eq 0) { $config->{'setup'}->{'os-tenant'} = $val; }}
			if ($key =~ "OS_AUTH_URL") { if (length($config->{'setup'}->{'os-auth-url'}) eq 0) { $config->{'setup'}->{'os-auth-url'} = $val; }}
		}
	}
    }
    if (!defined($config->{'setup'}->{'interval'})) { $config->{'setup'}->{'interval'} = 300; }
    if (!defined($config->{'setup'}->{'samples'})) { $config->{'setup'}->{'samples'} = 3; }
    if (!defined($config->{'setup'}->{'mysql-CRIT'})) { $config->{'setup'}->{'mysql-CRIT'} = 600; }
    if (!defined($config->{'setup'}->{'rabbit-CRIT'})) { $config->{'setup'}->{'rabbit-CRIT'} = 10; }
    if (!defined($config->{'setup'}->{'mysql-WARN'})) { $config->{'setup'}->{'mysql-WARN'} = 300; }
    if (!defined($config->{'setup'}->{'rabbit-WARN'})) { $config->{'setup'}->{'rabbit-WARN'} = 5; }
    if (!defined($config->{'setup'}->{'mysql_defaults_file'}) || ($config->{'setup'}->{'mysql_defaults_file'} eq '')) {
        if ( -e '/root/.my.cnf') { $config->{'setup'}->{'mysql_defaults_file'} = '/root/.my.cnf'; }
    } else {
        if (!( -e $config->{'setup'}->{'mysql_defaults_file'})) { 
            $config->{'setup'}->{'mysql_defaults_file'} = undef; 
        } else {
            nimLog(1, "Defaults file '$config->{setup}->{mysql_defaults_file} not found; ignoring");
        }
    }
}
sub init_setup {
    readConfig();
    $config->{'status'}->{'next_run'} = time(); 
    $config->{'status'}->{'rabbit'}->{'samples'} = 0;
    $config->{'status'}->{'rabbit'}->{'triggered'} = 0;
    $config->{'status'}->{'volumeGroup'}->{'samples'} = 0;
    $config->{'status'}->{'volumeGroup'}->{'triggered'} = 0;
    $config->{'status'}->{'nova'}->{'samples'} = 0;
    $config->{'status'}->{'nova'}->{'triggered'} = 0;
    $config->{'status'}->{'neutron'}->{'samples'} = 0;
    $config->{'status'}->{'neutron'}->{'triggered'} = 0;
    $config->{'status'}->{'keystone'}->{'samples'} = 0;
    $config->{'status'}->{'keystone'}->{'triggered'} = 0;
    $config->{'status'}->{'glance'}->{'samples'} = 0;
    $config->{'status'}->{'glance'}->{'triggered'} = 0;
    $config->{'status'}->{'kvm'}->{'samples'} = 0;
    $config->{'status'}->{'kvm'}->{'triggered'} = 0;
    $config->{'status'}->{'Slave_IO_Running'}->{'last'} = 0; 
    $config->{'status'}->{'Slave_IO_Running'}->{'samples'} = 0; 
    $config->{'status'}->{'Slave_IO_Running'}->{'triggered'} = 0;
    $config->{'status'}->{'Slave_SQL_Running'}->{'last'} = 0; 
    $config->{'status'}->{'Slave_SQL_Running'}->{'samples'} = 0; 
    $config->{'status'}->{'Slave_SQL_Running'}->{'triggered'} = 0;
    $config->{'status'}->{'Seconds_Behind_Master'}->{'last'} = 0; 
    $config->{'status'}->{'Seconds_Behind_Master'}->{'samples'} = 0; 
    $config->{'status'}->{'Seconds_Behind_Master'}->{'triggered'} = 0;
}

sub ctrlc {
    exit;
}

getopts( "d:l:i:", \%options );
$SIG{INT} = \&ctrlc;
init_setup();
my $sess = Nimbus::Session->new("$prgname");
$sess->setInfo($version, "Rackspace The Open Cloud Company");

if ($sess->server(NIMPORT_ANY, \&timeout, \&init_setup) == NIME_OK) {
    nimLog( 0, "server session is created" );
} else {
    nimLog( 0, "unable to create server session" );
    exit(1);
}

$sess->dispatch();
nimLog(0, "Received STOP, terminating program");
nimLog(0, "Exiting program" );
exit(0);
