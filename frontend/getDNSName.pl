#!/usr/bin/perl

use strict;
use warnings;

#this tool requires the use of 'dig'

if(scalar (@ARGV) !=1){
    print <<USAGE;
Usage: $0 ip
USAGE
    exit;
}

#we accept IPs or prefixes as parameters
my $prefix=$ARGV[0];

if($prefix=~/([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})/){
    my $ip=$1;
    if($ip eq '0.0.0.0'){
	print 'OTHERS', "\n";
	exit;
    }
#    print "Got IP $ip\n";
    my @output=`dig -x $ip +time=1 | grep -A 1 "^;; ANSWER SECTION:"`;
    foreach my $line(@output){
	if($line=~/\s+PTR\s+(.*)/){
	    my $dnsName=$1;
	    print $dnsName."\n";
	}
    }
}
