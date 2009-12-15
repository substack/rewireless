#!/usr/bin/env perl
use warnings;
use strict;
use Time::HiRes qw/sleep/;
use List::AllUtils qw/first/;

# TODO:
# * push configuration out into ~/.config/rewireless/Config.pm
# * add wep support (should be simple enough)
# * auto-generate wpa config and add options to Config.pm

# allowed access points in the order of precedence
my @allowed = (
    # these can be strings
    # qw/linksys pigeonNET .../,
    
    # or regular expressions
    # qr/^ College \  Coffeehouse \  WiFi \  \d $/x,
);

my %wpa;
{
    open my $fh, "<", "/etc/wpa_supplicant/wpa_supplicant.conf" or die $!;
    for my $line (<$fh>) {
        my ($essid) = $line =~ m/^ \s+ ssid = " ([^"]+) "/x or next;
        $wpa{$essid} = 1;
    }
    close $fh;
}

system qw/sudo ifconfig wlan0 up/;

# grab signals out of iwlist
my @signals =
    grep defined $_->{ESSID},
    map {
        my %h = grep length, grep defined,
            split /
                \s* ([A-Z][^=\n]+)=
                | ^ \s* ([A-Z][^:]+) : \s*
            /mx;
        s/\n//g for values %h;
        \%h;
    }
    grep !/^wlan0/,
    split m/Cell \s+ \d+ \s+ - \s+/x,
    do { do {
        $_ = qx/sudo iwlist wlan0 scan/;
        sleep 1 unless $_;
   } until $_; $_ };

# map by essid with some cleanup and calculations
my %nodes;
for my $sig (@signals) {
    $sig->{ESSID} =~ s/^ " | " $//gx;
    my $id = $sig->{ESSID};
    $sig->{Quality} =~ s{ (\d+) / (\d+) }{ $1 / $2 }ex;
    $nodes{$id} //= [];
    push @{$nodes{$id}}, $sig;
}

# skip through each rule until one of them matches
for my $rule (@allowed) {
    my $essid = first {
        if (ref $rule eq "Regexp") {
            $_ =~ $rule;
        }
        elsif (ref $rule eq "CODE") {
            $rule->($nodes{$_});
        }
        elsif (ref $rule eq "") {
            $rule eq $_
        }
    } keys %nodes;
    defined $essid or next;
    
    my $wpa_alive = qx/ps -u root -o cmd/ =~ m{^ (?: \S*/|) wpa_supplicant }xm;
    
    if (exists $wpa{$essid} and not $wpa_alive) {
        print "Starting wpa_supplicant\n";
        system qw{ sudo wpa_supplicant
            -B -Dwext -iwlan0
            -c /etc/wpa_supplicant/wpa_supplicant.conf
        };
    }
    elsif (not exists $wpa{$essid} and $wpa_alive) {
        print "Killing wpa_supplicant\n";
        system qw/sudo killall wpa_supplicant/;
    }
    
    print "Connecting to $essid\n";
    
    # rank access points by quality, descending
    my @rank = sort { $b->{Quality} <=> $a->{Quality} } @{$nodes{$essid}};
    for my $node (@rank) {
        print "    ap: $node->{Address}\n";
        system qw/sudo iwconfig wlan0 essid off ap off mode managed/;
        system qw/sudo ifconfig wlan0 down/;
        system qw/sudo iwconfig wlan0/,
            essid => $essid,
            ap => $node->{Address};
            #channel => $node->{Channel};
        system qw/sudo ifconfig wlan0 up/;
        
        # ~ 3 seconds to connect or else move along to the next node
        my $tries = 0;
        until ($tries++ >= 20) {
            if (qx/iwconfig wlan0/ =~ m/\Q$node->{Address}/) {
                system qw/sudo dhclient wlan0/;
                last;
            }
            sleep 1;
        }
        exit if qx/ifconfig wlan0/ =~ m/inet6? addr:\s*(\S+)/;
    }
}
