#!/usr/bin/perl
use strict;
use warnings;

if ( scalar(@ARGV) < 1 || scalar(@ARGV) > 2 ) {
    print <<USAGE;

usage: getASName.pl AS9050 [fast]

USAGE
    exit;
}

my $asn = $ARGV[0];
my $speed = $ARGV[1] || undef;

if ( $asn eq 'AS65536' ) {
    print 'OTHERS', "\n";
    exit;
}

exit if (! defined $asn);

#1. load known ASNs from asn.txt into a hash
open ASN, "<asn.txt" or die "Unable to open asn.txt for reading\n";
my %knownASes;
while (<ASN>) {
    my $line = $_;
    chomp $line;
    $line =~ /^(AS[0-9]{1,5})\t(.*)$/;
    my $as   = $1;
    my $name = $2;
    
    next if (! defined $name);

    #print it the quick way
    print $name. "\n" if ( $as eq $asn );
    exit              if ( $as eq $asn );

    $knownASes{"$as"} = $name;

}
close ASN;

#3. if the ASN is not found, query ripe and SAVE the ASN in asn.txt

#we don't know it, and we don't want to know it...
exit if ( defined $speed && $speed eq 'fast' );

#do it the hard way...
#query RADB - should resolve ripe, arin, apnic, etc.
my @output = `whois -h whois.radb.net $asn | grep "^descr:"`;
my $name   = undef;
foreach my $line (@output) {
    if ( $line =~ /^descr:\s+(.*)$/ ) {
        $name = $1;
        $name = undef if ( $name =~ /ARIN/ );
        last;
    }
}
if ( !defined $name ) {

    #as is not registered with ripe.
    #query arin

    @output = `whois -h whois.arin.net $asn | grep "OrgName:"`;
    foreach my $line (@output) {
        if ( $line =~ /^OrgName:\s+(.*)$/ ) {
            $name = $1;
            last;
        }
    }
}
if ( !defined $name ) {

    #we don't know who this is
    $name = "$asn";
}

#add the new one now
$knownASes{$asn} = $name;

#4. return the description
print "$name\n";

#save it for further reference
open ASN, ">asn.txt" or die "Unable to open asn.txt for writing\n";
foreach my $as ( keys %knownASes ) {
    print ASN "$as\t$knownASes{$as}\n";
}

close ASN;

exit;
