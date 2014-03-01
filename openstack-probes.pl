#!$NIM_BIN/perl
#openstack-probes - Nimbus probe to monitor openstack
#Copyright (C) 2014  Jake Briggs jake.briggs@rackspace.com
#
#This program is free software: you can redistribute it and/or modify
#it under the terms of the GNU General Public License as published by
#the Free Software Foundation, either version 3 of the License, or
#(at your option) any later version.
#
#This program is distributed in the hope that it will be useful,
#but WITHOUT ANY WARRANTY; without even the implied warranty of
#MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#GNU General Public License for more details.

use strict;
use IO::Socket::INET;
use Getopt::Std;
use Nimbus::API;
use Nimbus::Session;
use Nimbus::CFG;
use Data::Dumper;
use Switch;
use Socket;
$| = 1;

my $prgname = 'openstack-probes';
my $version = '0.20';
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

sub blackAndWhite {
    my ($message, $goodOrBad) = @_;
    my $logMessage;
    switch ($message) {
        case "RabbitConnection" {
            $logMessage = "RabbitMQ not reachable....Is the service running?";
        }
        case "NovaConnection" {
            $logMessage = "Something is wrong!!! Nova-manage did not respond correctly.";
        }
        case "KeystoneConnection" {
            $logMessage = "Something is wrong!!! Keystone did not respond correctly.";
        }
        case "GlanceConnection" {
            $logMessage = "Something is wrong!!! Glance did not respond correctly.";
        }
        case "NeutronServerConnection" {
            $logMessage = "Something is wrong!!! Local Neutron/Quantum server did not respond correctly.";
        }
        case "NeutronConnection" {
            $logMessage = "Something is wrong!!! Neutron/Quantum did not respond correctly.";
        }
        case "KvmConnection" {
            $logMessage = "Something is wrong!!! LibVirt did not respond correctly.";
        }
        case "MemCachedConnection" {
            $logMessage = "Something is wrong!!! MemCached did not respond correctly.";
        }
        case "CinderConnection" {
            $logMessage = "Something is wrong!!! Local Cinder-Api Service did not respond correctly.";
        }
        case "NoVncProxyConnection" {
            $logMessage = "Something is wrong!!! Local Nova-NoVncProxy Service did not respond correctly.";
        }
        case "HorizonConnection" {
            $logMessage = "Something is wrong!!! Local Apache Service did not respond correctly.";
        }
        case "OvsDBConnection" {
            $logMessage = "Something is wrong!!! Local ovsdb-server Service did not respond correctly.";
        }
        case "OvsSwitchdConnection" {
            $logMessage = "Something is wrong!!! Local ovs-vswitchd Service did not respond correctly.";
        }
        else {
            $logMessage = "Something is really wrong!!!";
        }

    }
    if ( $goodOrBad == 1 ) {
        nimLog(1, $logMessage);
        $config->{'status'}->{$message}->{'samples'}++;
        if ($config->{'status'}->{$message}->{'samples'} >= $config->{'setup'}->{'samples'}) {
            if ($config->{'status'}->{$message}->{'triggered'} == 0){
                nimLog(1, "Max attempts reached. Creating an alert!");
                nimAlarm( $config->{'messages'}->{$message}->{'level'},$config->{'messages'}->{$message}->{'text'},$sub_sys,nimSuppToStr(0,0,0,$message));
                $config->{'status'}->{$message}->{'triggered'} = 1;
            }
        }
    } else {
        if ($config->{'status'}->{$message}-{'triggered'} == 1){
            $config->{'status'}->{$message}->{'samples'} = 0;
            nimLog(1, "All Clear!!");
            nimAlarm( NIML_CLEAR, $config->{'messages'}->{$message}->{'clear'},$sub_sys,nimSuppToStr(0,0,0,$message));
        }

    }
    return
}

sub checkOvs {
	if (-e '/usr/bin/ovsdb-client'){
		nimLog(1, "Checking ovsdb-server status...");
		my @data = `ovsdb-client list-dbs`;
		if ( $? != 0 || !@data ){
			blackAndWhite("OvsDBConnection",1);
		} else {
			blackAndWhite("OvsDBConnection",0);
		}
		@data = `ovs-vsctl list-br`;
		if ( $? != 0 || !@data ){
			blackAndWhite("OvsSwitchdConnection",1);
		} else {
			blackAndWhite("OvsSwitchdConnection",0);
		}
	} else {
		nimLog(1, "OVS NOT detected. Skipping...");
	}
}

sub checkHorizon {
	if (-e '/etc/openstack-dashboard'){
		nimLog(1, "Horizon found checking status...");
		my $host = `hostname`;
		chomp($host);
		my $address = inet_ntoa( scalar gethostbyname( $host || 'localhost' ));
		my @data = `curl -f -s http://$address:6080/vnc_auto.html`;
		if ( $? != 0 || !@data ){
			blackAndWhite("NoVncProxyConnection",1);
		} else {
			blackAndWhite("NoVncProxyConnection",0);
		}
		@data = `curl -f -s -k https://$address`;
		if ( $? != 0 || !@data ){
			blackAndWhite("HorizonConnection",1);
		} else {
			blackAndWhite("HorizonConnection",0);
		}
	} else {
		nimLog(1, "Horizon NOT detected. Skipping...");
	}
}

sub checkMemcached {
	if ( -e '/etc/init.d/memcached' ) {
        	nimLog(1, "MemCached Detected. Checking Status...");
		my $host = `hostname`;
		my $host1= "127.0.0.1";
		chomp($host);
		$host .= ":11211";
		$host1 .= ":11211";
		my $sock = IO::Socket::INET->new(PeerAddr => $host, Proto => 'tcp');
		my $sock1 = IO::Socket::INET->new(PeerAddr => $host1, Proto => 'tcp');
		if ( $sock || $sock1 ) {
			blackAndWhite("MemCachedConnection",0);
			if ( $sock ) { $sock->close(); } else { $sock1->close(); }
		} else {
			blackAndWhite("MemCachedConnection",1);
		}
	} else {
        	nimLog(1, "MemCached NOT detected. Skipping.");
	}
}

sub checkMetadata {
    nimLog(1, "Checking Neutron-Metadata Services...");

    # DHCP things
    my @dhcpdata;
    if (-e '/var/lib/neutron/dhcp'){ @dhcpdata = `ls /var/lib/neutron/dhcp | grep -v "lease_relay"`; }
    if (-e '/var/lib/quantum/dhcp'){ @dhcpdata = `ls /var/lib/quantum/dhcp | grep -v "lease_relay"`; }
    chomp(@dhcpdata);
    nimLog(1, 'Returned '.scalar(@dhcpdata).' lines from Neutron/Quantum DHCP');
    # Build an array of only uuids
    my @dhcpuuids = ();
    foreach my $str (@dhcpdata) {
        if ( $str =~ /(^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$)/ ) {
            push(@dhcpuuids, lc($1));
        }
    }

    # Net list things
    my @netlistdata;
    if ( -e '/usr/bin/neutron' ) {
        @netlistdata = `/usr/bin/neutron --os-username $config->{'setup'}->{'os-username'} --os-tenant-name $config->{'setup'}->{'os-tenant'} --os-auth-url $config->{'setup'}->{'os-auth-url'} --os-password $config->{'setup'}->{'os-password'} net-list 2>/dev/null`;
    } else {
        @netlistdata = `/usr/bin/quantum --os-username $config->{'setup'}->{'os-username'} --os-tenant-name $config->{'setup'}->{'os-tenant'} --os-auth-url $config->{'setup'}->{'os-auth-url'} --os-password $config->{'setup'}->{'os-password'} net-list 2>/dev/null`;
    }
    chomp(@netlistdata);
    nimLog(1, 'Returned '.scalar(@netlistdata).' lines from Neutron/Quantum Net List');
    my @netlistuuids = ();
    for my $str (@netlistdata) {
        my @tokens = split(' ', $str);
        if (scalar(@tokens) > 1) {
            if (@tokens[1] =~ /(^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$)/ ) {
                push(@netlistuuids, lc($1));
            }
        }
    }

    # Merge the uuids into one array if in both
    my @data = ();
    foreach my $dhcpuuid (@dhcpuuids) {
        foreach my $netlistuuid (@netlistuuids) {
            if ($dhcpuuid eq $netlistuuid) {
                push(@data, $dhcpuuid);
                last;
            }
        }
    }
    nimLog(1, 'Returned '.scalar(@data).' lines from Neutron/Quantum Intersection of DHCP and Net List');
	foreach my $value (@data) {
		$value =~ s/^\s*(.*?)\s*$/$1/;
		my @response = `ip netns exec qdhcp-$value curl -f -s 169.254.169.254`;
		if ( $? ne "5632" ) {
			if (!defined($config->{'status'}->{$value}->{'samples'})){$config->{'status'}->{$value}->{'samples'} = 0;};
			if (!defined($config->{'status'}->{$value}->{'triggered'})){$config->{'status'}->{$value}->{'triggered'} = 0;};
			$config->{'status'}->{$value}->{'samples'}++;
			if ($config->{'status'}->{$value}->{'samples'} >= $config->{'setup'}->{'samples'}) {
				if ($config->{'status'}->{$value}->{'triggered'} == 0){
					nimLog(1, "Critical alert on (neutron/quantum)-metadata service for network $value");
					my $alert_string = "[CRITICAL] (Neutron/Quantum)-metadata Service attached to network $value is not responding. Please investigate.";
					nimAlarm( 5,$alert_string,$sub_sys,nimSuppToStr(0,0,0,"neutronmetadataservice"));
					$config->{'status'}->{$value}->{'triggered'} = 1;
				}
			}
		} else {
			$config->{'status'}->{$value}->{'samples'} = 0;
			if ($config->{'status'}->{$value}->{'triggered'} == 1){
				nimLog(1, "(Neutron/Quantum)-metadata service for network $value has checked in.");
				my $alert_string = "(Neutron/Quantum)-metadata Service for network $value Alert clear";
				nimAlarm( NIML_CLEAR,$alert_string,$sub_sys,nimSuppToStr(0,0,0,"neutronmetadataservice"));
				$config->{'status'}->{$value}->{'triggered'} = 0;
			}
		}
	}
}

sub checkRabbit {
    my @data;
    if ( -e '/etc/init.d/rabbitmq-server' ) {
        nimLog(1, "RabbitMQ detected. Checking status...");
        @data = `$config->{'setup'}->{'rabbitmq_cmd_line'} list_queues 2>/dev/null`;
        if ($? != 0 || !@data) {
            blackAndWhite("RabbitConnection",1);
            return;
        } else {
            blackAndWhite("RabbitConnection",0);
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
            blackAndWhite("NovaConnection",1);
            return;
        } else {
            blackAndWhite("NovaConnection",0);
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
    my $host = `/bin/hostname`;
    chomp($host);
    if (-e '/usr/bin/keystone-all' ){
        nimLog(1, "Keystone detected. Checking status...");
        @data = `/usr/bin/keystone --os-username $config->{'setup'}->{'os-username'} --os-tenant-name $config->{'setup'}->{'os-tenant'} --os-auth-url http://$host:5000/v2.0 --os-password $config->{'setup'}->{'os-password'} token-get 2>/dev/null`;
        if ($? != 0 || !@data) {
            blackAndWhite("KeystoneConnection",1);
        } else {
            blackAndWhite("KeystoneConnection",0);
	    my @token = split(' ',@data[4]);
	    $config->{'setup'}->{'keystone-token'} = @token[3];
	    my @token = split(' ',@data[5]);
	    $config->{'setup'}->{'keystone-tenant'} = @token[3];
	    my @token = split(' ',@data[6]);
	    $config->{'setup'}->{'keystone-user'} = @token[3];
        } 
    }
}

sub checkGlance {
    my @data;
    if (-e '/usr/bin/glance-manage' ){
        nimLog(1, "Glance detected. Checking status...");
        @data = `/usr/bin/glance --os-username $config->{'setup'}->{'os-username'} --os-tenant-name $config->{'setup'}->{'os-tenant'} --os-auth-url $config->{'setup'}->{'os-auth-url'} --os-password $config->{'setup'}->{'os-password'} index 2>/dev/null`;
        if ($? != 0 || !@data) {
            blackAndWhite("GlanceConnection",1);
            return;
        } else {
            blackAndWhite("GlanceConnection",0);
        } 
    }
}

sub checkNeutronServer {
    my @data;
    my $host = `hostname`;
    chomp($host);
    if ( -e '/etc/init.d/neutron-server' || -e '/etc/init.d/quantum-server' ) {
        nimLog(1, "Local Neutron/Quantum server detected. Checking status...");
        @data = `curl -f -H "X-Auth-Token:$config->{'setup'}->{'keystone-token'}" http://$host:9696/v2.0/networks`;
        if ($? != 0 || !@data) {
            blackAndWhite("NeutronServerConnection",1);
        } else {
            nimLog(1, 'Returned '.scalar(@data).' lines from Neutron/Quantum');
            blackAndWhite("NeutronServerConnection",0);
        }
    }
}

sub checkNeutron {
	my @data;
	my $host = `hostname`;
	chomp($host);
	if ( -e '/etc/neutron' || -e '/etc/quantum' ) {
		checkOvs();
		nimLog(1, "Neutron/Quantum agent(s) detected. Checking status...");
		if ( -e '/usr/bin/neutron' ) {
			@data = `/usr/bin/neutron --os-username $config->{'setup'}->{'os-username'} --os-tenant-name $config->{'setup'}->{'os-tenant'} --os-auth-url $config->{'setup'}->{'os-auth-url'} --os-password $config->{'setup'}->{'os-password'} agent-list 2>/dev/null`;
		} else {
			@data = `/usr/bin/quantum --os-username $config->{'setup'}->{'os-username'} --os-tenant-name $config->{'setup'}->{'os-tenant'} --os-auth-url $config->{'setup'}->{'os-auth-url'} --os-password $config->{'setup'}->{'os-password'} agent-list 2>/dev/null`;
		}
		if ($? != 0 || !@data) {
			blackAndWhite("NeutronConnection",1);
		} else {
			blackAndWhite("NeutronConnection",0);
			nimLog(1, 'Returned '.scalar(@data).' lines from Neutron/Quantum');
			my @service_list;
			shift @data;
			shift @data;
			shift @data;
			pop @data;
			foreach my $line (@data) {
				my $service = {};
				my @values = split('\|',$line);
				if (@values[3] =~ /$host/) {
					$service->{@values[2]} = @values[4];
					push @service_list,$service;
				}
			}
			for my $i (@service_list) {
				while ( my ($key, $value) = each %{$i} ) {
					if ( $key =~ m/DHCP/){ checkMetadata() };
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
			}
		}
	} else {
		nimLog(1, "Neutron/Quantum NOT detected. Skipping.");
	}
}

sub checkCinder {
	my $host = `hostname`;
	my @data;
	my $localApi;
	chomp($host);
	if ( -e '/etc/init.d/cinder-api' || -e '/etc/init.d/openstack-cinder-api' ){
		nimLog(1, "Local APIs found. Checking");
		$localApi = 1;
		@data = `curl -f -s -i http://$host:8776/v1/$config->{'setup'}->{'keystone-tenant'}/os-services -X GET -H "X-Auth-Project-Id: admin" -H "User-Agent: nimbus" -H "Accept: application/xml" -H "X-Auth-Token: $config->{'setup'}->{'keystone-token'}"`;
	} else {
		nimLog(1, "Local APIs NOT found. Checking Cinder via VIP");
		$localApi = 0;
		my @vip = split('5000',$config->{'setup'}->{'os-auth-url'});
		@data = `curl -f -s -i $vip[0]:8776/v1/$config->{'setup'}->{'keystone-tenant'}/os-services -X GET -H "X-Auth-Project-Id: admin" -H "User-Agent: nimbus" -H "Accept: application/xml" -H "X-Auth-Token: $config->{'setup'}->{'keystone-token'}"`;
	}
	if ($? != 0 || !@data) {
		if ( $localApi == 1 ){
			blackAndWhite("CinderConnection",1);
		}
	} else {
		blackAndWhite("CinderConnection",0);
		nimLog(1, 'Returned '.scalar(@data).' lines from Cinder-Api');
		my $last = pop @data;
		my @values = split('>',$last);
		shift @values;
		pop @values;
		foreach (@values){
			my @line = split(' ',$_);
			chop($line[5]);
			if ($line[5] =~ $host){
				nimLog(1, "Checking Cinder Service ".$line[2]."...");
				if (!defined($config->{'status'}->{'cinder'}->{$line[2]}->{'samples'})){$config->{'status'}->{'cinder'}->{$line[2]}->{'samples'} = 0;};
				if (!defined($config->{'status'}->{'cinder'}->{$line[2]}->{'triggered'})){$config->{'status'}->{'cinder'}->{$line[2]}->{'triggered'} = 0;};
				if ($line[1] =~ "enabled" && $line[4] =~ "up"){
					$config->{'status'}->{'cinder'}->{$line[2]}->{'samples'} = 0;
					if ( $config->{'status'}->{'cinder'}->{$line[2]}->{'triggered'} == 1 ){
						my $alert_string = "Cinder Service $line[2] has checked in. This alert is clear.";
						nimLog(1, $alert_string);
						nimAlarm( NIML_CLEAR,$alert_string,$sub_sys,nimSuppToStr(0,0,0,"cinderservice"));
						$config->{'status'}->{'cinder'}->{$line[2]}->{'triggered'} = 0;
					}
				} else {
					$config->{'status'}->{'cinder'}->{$line[2]}->{'samples'}++;
					if ($config->{'status'}->{'cinder'}->{$line[2]}->{'samples'} >= $config->{'setup'}->{'samples'}) {
						if ($config->{'status'}->{'cinder'}->{$line[2]}->{'triggered'} == 0){
							my $alert_string = "Warning Cinder Service $line[2] has not checked in. Please investigate.";
							nimLog(1, $alert_string);
							nimAlarm( 5,$alert_string,$sub_sys,nimSuppToStr(0,0,0,"cinderservice"));
							$config->{'status'}->{'cinder'}->{$line[2]}->{'triggered'} = 1;
						}
					}
				}
			}
		}
	}
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
            blackAndWhite("KvmConnection",1);
            return;
        } else {
            blackAndWhite("KvmConnection",0);
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
	checkKeystone();
	checkMemcached();
	checkNeutronServer();
	checkRabbit();
	checkMysql();
	checkNova();
	checkNeutron();
	checkCinder();
	checkGlance();
	checkKvm();
	checkHorizon();
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
    $config->{'status'}->{'RabbitConnection'}->{'samples'} = 0;
    $config->{'status'}->{'RabbitConnection'}->{'triggered'} = 0;
    $config->{'status'}->{'volumeGroup'}->{'samples'} = 0;
    $config->{'status'}->{'volumeGroup'}->{'triggered'} = 0;
    $config->{'status'}->{'NovaConnection'}->{'samples'} = 0;
    $config->{'status'}->{'NovaConnection'}->{'triggered'} = 0;
    $config->{'status'}->{'nova'}->{'samples'} = 0;
    $config->{'status'}->{'nova'}->{'triggered'} = 0;
    $config->{'status'}->{'neutron'}->{'samples'} = 0;
    $config->{'status'}->{'neutron'}->{'triggered'} = 0;
    $config->{'status'}->{'NeutronMetadata'}->{'samples'} = 0;
    $config->{'status'}->{'NeutronMetadata'}->{'triggered'} = 0;
    $config->{'status'}->{'NeutronConnection'}->{'samples'} = 0;
    $config->{'status'}->{'NeutronConnection'}->{'triggered'} = 0;
    $config->{'status'}->{'NeutronServerConnection'}->{'samples'} = 0;
    $config->{'status'}->{'NeutronServerConnection'}->{'triggered'} = 0;
    $config->{'status'}->{'KeystoneConnection'}->{'samples'} = 0;
    $config->{'status'}->{'KeystoneConnection'}->{'triggered'} = 0;
    $config->{'status'}->{'GlanceConnection'}->{'samples'} = 0;
    $config->{'status'}->{'GlanceConnection'}->{'triggered'} = 0;
    $config->{'status'}->{'KvmConnection'}->{'samples'} = 0;
    $config->{'status'}->{'KvmConnection'}->{'triggered'} = 0;
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
