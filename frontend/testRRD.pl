#!/usr/bin/perl
use strict;
use warnings;

use RRDs;

my $file="rrds/_InternetTraffic/as1234.rrd";
my $function = "MAX";
my $tstart="1180607090";
my $tend="1180607590";
my $ds="inbound_bps";

my($start, $step, $names, $data) = RRDs::fetch($file, $function, '--start' => $tstart, '--end' => $tend, );
if(RRDs::error())
{
   die ("Can't export data: " . RRDs::error());
}

# get DS id
my $value;
my $found = 0;
for(my $i = 0; $i < @$names; $i++)
{
   if($names->[$i] eq $ds)
   {
         $found = 1;
         $value = $data->[0]->[$i];
	 
	 print "Found $value bps for $ds at time $start\n" if (defined $value);
	 
         last;
    }
}

if(!$found)
{
    die "Can't find datasource $ds\n"; 
}
