#!/usr/bin/perl

# CHANGELOG:
# v 2.0.0 - Added version numbers
# v 2.0.2 - Added support for srcAS and dstAS determination and selection;
#	    also, if a border has only one monitored interface, we'll draw only global graphs for it
# v 2.0.4 - Added optimization - generation of the png images is optional in the module. It can be done in the web interface.
#	    The feature is controlled by the $drawGraphsOnRequest variable.
# v 2.0.5 - A lot of cleanups; configuration is controlled from a master file.
# v 2.0.6 - Added possibility to compensate sampling in graphs
#	  - Added graphs by source prefix (can be specified on each border)
#	  - Added support for top 10 source talkers, per border
# v 2.0.7 - Added support for collecting 'other' statistics when doing top 10 hosts, top 10 ASes
#	  - Added support for drawing (or not) these 'other' statistics in the pie charts.
# v 2.0.8 - Drastically modified the configuration file. Introduced the new prefixStatsConfig.pm module to help configuration.
# v 2.0.9 - Added rrd update and rrd drawing processes to prefixStatsConfig.pm. Cleaned up the code.
# v 2.1.0 - Added ability to draw pie chart for traffic per AS/prefix and per Interface
#         - Now we are collecting the requested top AS per interface
#	  - Added support for 'internet' traffic for a list of ASs (sum of traffic per border).
#	  - Added support for 'internet' traffic for a list of prefixes (must match the dstPrefixes defined for each InternetRouter)
# v 2.1.2 - Fix internet traffic bug
# v 2.1.3 - Increase efficiency when parsing for AS. Collect less redundant data, faster. Introduces $ASEfficiency=1;
# v 2.2.0 - Major changes to how AS data is stored. Now it's inas instead of srcas and outas instead of dstas
#	  - Fixed major bug which made AS traffic appear 20 times bigger than it actually was (took me a month to see that this bug existed!)
#	  - Added zooming support for graphs in the web interface (stolen shamelessly from cacti)
# v 2.2.1 - Fixed for nfsen/nfdump v1.3
#	  - filter syntax changes from inif to in if, srcas to src as, etc.
# v 2.2.2 - Code cleanup & first public version
# v 2.2.3 - Stop correcting sampling rate - nfsen should do it automatically from version 1.6.1
# v 2.2.4 - Add drawTopXSources per interface, not per router

#  AS processing details/convention:
#  - the ASes are processed as srcas/dstas per interface (inif/outif) and are stored in a structure like this:
#         $ASes{$border}{srcas1234}{inif}=value [bytes]
#    this value is converted to bits per second before updating the rrd file.
#  - the rrd structure has changed from srcas1234/dstas179 to inas1234/outas179 to take into account interface direction (inif/outif)
#  - the following conversion has been applied:
#         srcas & outif => inas 'outbound'
#	  dstas & inif  => inas 'inbound'
#	  srcas & inif  => outas 'inbound'
#	  dstas & outif => outas 'outbound'
#
#

package prefixStats;

use strict;

#no strict "refs";  #to allow %$string
use NfSen;
use NfConf;
use RRD::Simple ();

use Log::Log4perl qw(get_logger :levels);

#
# The plugin may send any messages to syslog
# Do not initialize syslog, as this is done by
# the main process nfsen-run
use Sys::Syslog;
Sys::Syslog::setlogsock('unix');
openlog( "prefixStats", "", "local0" );

# Use the optional Notification module
#use Notification;

our $VERSION = 130;

my ( $nfdump, $PROFILEDIR );

#load configuration

#we assume the CONFDIR is hardcoded (it's set at installation time)
my $CONFDIR  = '/data/nfsen/etc';
my $CONFFILE = 'prefixStats.conf';

#we load the configuration.
# read prefixStats.conf from CONFDIR

if ( !-f "$CONFDIR/$CONFFILE" ) {
    get_logger()->error("Unable to read configuration file $CONFDIR/$CONFFILE!");
    exit;
}

do "$CONFDIR/$CONFFILE" or get_logger()->error("Unable to execute configuration file $CONFDIR/$CONFFILE");

# load the configuration module.
use lib '/data/nfsen/plugins';
use prefixStatsConfig;

# get a reference to the main sub used to get the configuration.
my $getConfig = \&prefixStatsConfig::getConfig;
my $rrdUpdate = \&prefixStatsConfig::rrdUpdate;
my $rrdDraw   = \&prefixStatsConfig::rrdDraw;

# set local variables to their configuration conunterparts.

my $rrdPath                   = $PSConfig::rrdDir;
my $pictureDir                = $PSConfig::pictureDir;
my $internetTrafficRRDDir     = $PSConfig::internetTrafficRRDDir;
my $internetTrafficPictureDir = $PSConfig::internetTrafficPictureDir;
my %sources                   = %PSConfig::sources;
my %process                   = %PSConfig::process;
my %internetTraffic           = %PSConfig::internetTraffic;
my %internetTrafficPrefix     = %PSConfig::internetTrafficPrefix;
my $drawGraphsOnRequest       = $PSConfig::drawGraphsOnRequest;
my $ASEfficiency              = $PSConfig::ASEfficiency;
my @borders                   = $getConfig->( 'sources', \%sources );

print "number of sources:" . scalar( keys %sources ) . "; getConfig returned: " . $getConfig->( 'sources', \%sources ), "\n";

#set a correct umask, so that group has access to my files
umask 0002; #rwxrwxr-x allowed

#parsing strings...

#starts with: 2006-08-23 23:32:27.884
my $date_time_string = "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}";

#duration: 1290.560
my $duration_string = "[0-9]{1,}\.[0-9]{3}";

#proto: UDP
my $proto_string = "[0-9A-Za-z-]{1,}";

#src IP
my $src_ip_string = "[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}";

#src Port
my $src_port_string = "[0-9]{1,5}";

#dst IP
my $dst_ip_string = "[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}";

#dst port
my $dst_port_string = "[0-9]{1,5}";

#flags
my $flags_string = "[\.A-Z]{6}";

#Tos
my $tos_string = "[0-9]{1,3}";

#packets
my $packets_string = "(?:(?:[0-9]{1,})|(?:[0-9]{1,}\.[0-9] M)|(?:[0-9]{1,}\.[0-9] G))";

#bytes
my $bytes_string = "(?:(?:[0-9]{1,})|(?:[0-9]{1,}\.[0-9] M)|(?:[0-9]{1,}\.[0-9] G))";

#pps
my $pps_string = "(?:(?:[0-9]{1,})|(?:[0-9]{1,}\.[0-9] M)|(?:[0-9]{1,}\.[0-9] G))";

#bps
my $bps_string = "(?:(?:[0-9]{1,})|(?:[0-9]{1,}\.[0-9] M)|(?:[0-9]{1,}\.[0-9] G))";

#bpp
my $bpp_string = "(?:(?:[0-9]{1,})|(?:[0-9]{1,}\.[0-9] M)|(?:[0-9]{1,}\.[0-9] G))";

#flows
my $flows_string = "(?:(?:[0-9]{1,})|(?:[0-9]{1,}\.[0-9] M)|(?:[0-9]{1,}\.[0-9] G))";

#input_if
my $input_if_string = "[0-9]{1,}";

#output_if
my $output_if_string = "[0-9]{1,}";

#src_as
my $src_as_string = "[0-9]{1,5}";

#dst as
my $dst_as_string = "[0-9]{1,5}";

#
# Periodic function
#	input:	profilename
#			timeslot. Format yyyymmddHHMM e.g. 200503031200

#input changed in nfsen-snapshot-20070110. It comes as a hash now.

sub run {

    my $startTime = time();

    my $argref       = shift;
    my $profile      = $$argref{'profile'};
    my $profilegroup = $$argref{'profilegroup'};
    my $timeslot     = $$argref{'timeslot'};

    #	my $profile  = shift;
    #	my $timeslot = shift;

    #private logging
    get_logger()->debug("Profile: $profile, Time: $timeslot; Starting to calculate...");
    syslog( "info", "prefixStats run: Profile $profile, Time: $timeslot" );

    #	my %profileinfo     = NfSen::ReadProfile($profile);
    #	my $netflow_sources = "$PROFILEDIR/$profile/$profileinfo{'sourcelist'}";

    my %profileinfo = NfProfile::ReadProfile( $profile, $profilegroup );
    my $profilepath = NfProfile::ProfilePath( $profile, $profilegroup );
    my $all_sources = join ':', keys %{ $profileinfo{'channel'} };
    my $netflow_sources = "$PROFILEDIR/$profilepath/$all_sources";

    my %ASes;

    my %ASesTotal;

    my %srcPrefixData = ();

    my %srcIPData = ();

    my %internetTrafficValues = ();

    my %internetTrafficValuesPerPrefix = ();

    ###################################################################
    # draw traffic statistics based on border/interface/prefix|AS     #
    ###################################################################
    get_logger()->debug( "Ready for foreach borders (got " . scalar(@borders) . ")" );
    foreach my $border (@borders) {
        get_logger()->info("--- border: $border ---");

        my @prefixes = $getConfig->( 'dstPrefix', \%sources, $border );

        get_logger()->debug( "spoofThreshold for $border is: " . $getConfig->( 'spoofThreshold', \%sources, $border ) );

        #clear %ASesTotal;
        %ASesTotal = ();

        ##############################
        # draw traffic per interface #
        ##############################

        my %borderBPS;    #variable to store traffic for every prefix borderwide. (prefix =>{ inif=>, outif=>});
        my %interfaceDescriptions = $getConfig->( 'interfaces', \%sources, $border );
        foreach my $if ( keys %interfaceDescriptions ) {
            get_logger()->info( "--- interface: $if (" . $interfaceDescriptions{$if} . ") ---" );

            #clear %ASes

            %ASes = ();

            #############################
            # draw prefix per interface #
            #############################

            if ( $process{'prefix'} == 1 ) {
                foreach my $prefix (@prefixes) {
                    get_logger()->debug("Parsing for $border, interface $if, prefix $prefix");
                    my %bytes;
                    my @interfaceType = $getConfig->( 'interfaceType', \%sources, $border, $if );
                    foreach my $ifType (@interfaceType) {
                        my $modifiedIfType = $ifType;
                        $modifiedIfType =~ s/if/ if/;    #insert an extra space
                        my @output = `$nfdump -r /data/nfsen/profiles/live/$border/nfcapd.$timeslot -n 1 -s record/bytes -o "fmt:%ts %td %pr %sap -> %dap %pkt %byt %bps %in %out %sas %das %fl" '$modifiedIfType $if and net $prefix'`;

                      #			get_logger()->debug("CMD: $nfdump -r /data/nfsen/profiles/live/$border/nfcapd.$timeslot -n 1 -s record/bytes -o \"fmt:%ts %td %pr %sap -> %dap %pkt %byt %bps %in %out %sas %das %fl\" '$ifType $if and net $prefix'\n@output");

                        $bytes{$ifType} = 0;
                        if ( $output[-4] =~ /Summary: total flows: $bytes_string, total bytes: ($bytes_string), total packets:/ ) {
                            $bytes{$ifType} = $1;
                        }

                        # convert M & G to scalar values.
                        if ( $bytes{$ifType} =~ /[0-9]{1,}\.[0-9] M/ ) {    #we have bytes in M -> convert.
                            $bytes{$ifType} =~ s/M$//;                      #cut the M
                            $bytes{$ifType} = $bytes{$ifType} * 1000000;    #multiply by 1 milion
                        }
                        if ( $bytes{$ifType} =~ /[0-9]{1,}\.[0-9] G/ ) {    #we have bytes in G -> convert.
                            $bytes{$ifType} =~ s/G$//;                      #cut the G
                            $bytes{$ifType} = $bytes{$ifType} * 1000000000; #multiply by 1000 milion
                        }

                        #correct by the sampling rate, if we want to.
#                        $bytes{$ifType} *= $getConfig->( 'sampleRate', \%sources, $border ) if ( $getConfig->( 'multiplySamplingRate', \%sources, $border ) );

                    }

                    #now that we have the value(s), update the rrd and png.
                    if ( !-d "$rrdPath/$border/$if" || !-d "$pictureDir/$border/$if" ) {
                        mkdir( "$rrdPath/$border",        0777 );
                        mkdir( "$rrdPath/$border/$if",    0777 );
                        mkdir( "$pictureDir/$border",     0777 );
                        mkdir( "$pictureDir/$border/$if", 0777 );

                        chmod 0775, "$pictureDir", "$pictureDir/$border", "$pictureDir/$border/$if";

                    }

                    my $need_to_update = 0;

                    #compute bps
                    my %bps;
                    foreach my $ifType ( keys %bytes ) {
                        $bps{$ifType} = $bytes{$ifType} * 8 / 300;

                        if ( defined $borderBPS{$prefix} ) {

                            #just update
                        }
                        else {
                            $borderBPS{$prefix} = ();    #create a new record
                        }
                        $borderBPS{$prefix}{$ifType} += $bps{$ifType};    #add this to the total value.

                        if ( $bps{$ifType} > 0 ) {
                            $need_to_update = 1;                          #it means we have some traffic, and we need to update the graphs.
                        }

                        #		    $borderBPS{$prefix}+=$bps{ifType}; #add this to the total value.
                    }

                    #if we have only one interface, we'll draw *ONLY* global graphs to reduce the overhead
                    my %interfaceDescriptions = $getConfig->( 'interfaces', \%sources, $border );
                    if ( scalar( keys %interfaceDescriptions ) == 1 ) {

                        #skip the next part
                    }
                    else {

                        my $filename = $prefix;
                        $filename =~ s/\//_/g;    #get rid of /

                        if ( !$need_to_update ) {

                            #there's no traffic for this prefix on this border/interface, so skip it.
                            next;
                        }
                        get_logger()->debug("Got inbound bytes=$bytes{'inif'}, outbound bytes=$bytes{'outif'}, inbound bps=$bps{'inif'}, outbound bps=$bps{'outif'}");
                        $rrdUpdate->( 'filename' => "$rrdPath/$border/$if/$filename.rrd", 'inif' => "$bps{'inif'}", 'outif' => "$bps{'outif'}", 'type' => '2bps' );

                        if ( !$drawGraphsOnRequest ) {

                            #draw png files while we're at it...
                            $rrdDraw->(
                                'filename'    => "$rrdPath/$border/$if/$filename.rrd",
                                'dstfile'     => "$pictureDir/$border/$if/$filename-daily.png",
                                'destination' => "$pictureDir/$border/$if",
                                'title'       => "Traffic for $prefix (" . $interfaceDescriptions{$if} . " on $border)",
                                'type'        => '2bps'
                            );
                        }    #if(!$drawGraphsOnRequest)
                    }    #else

                    #####################################################
                    # record internet traffic prefix for this interface #
                    #####################################################

                    #is this an internet interface?
                    my $interfacePeerType = $getConfig->( 'ifPeerType', \%sources, $border, $if );
                    if ( $interfacePeerType eq 'internet' && defined $internetTrafficPrefix{$prefix} ) {

                        #sum the traffic for this interface in internet traffic

                        get_logger()->debug("Adding current values to Internet Traffic for prefix $prefix on $border and if $if");

                        if ( !defined $internetTrafficValuesPerPrefix{$prefix}{'inif'} ) {
                            $internetTrafficValuesPerPrefix{$prefix}{'inif'}  = 0;
                            $internetTrafficValuesPerPrefix{$prefix}{'outif'} = 0;
                        }
                        $internetTrafficValuesPerPrefix{$prefix}{'inif'}  += $bps{'inif'};
                        $internetTrafficValuesPerPrefix{$prefix}{'outif'} += $bps{'outif'};

                    }

                }    #foreach my prefix
            }    #if($process{'prefix'}==1)

            #################################
            # draw src prefix per interface #
            #################################
            my @srcPrefix = $getConfig->( 'srcPrefix', \%sources, $border );
            if ( scalar(@srcPrefix) ) {

                # we have some source prefixes defined for this border
                # parse, and gather the data.

                foreach my $prefix (@srcPrefix) {
                    get_logger()->debug("Parsing for $border, interface $if, source prefix $prefix");
                    my %bytes;
                    my @interfaceType = $getConfig->( 'interfaceType', \%sources, $border, $if );
                    foreach my $ifType (@interfaceType) {
                        my $modifiedIfType = $ifType;
                        $modifiedIfType =~ s/if/ if/;    #insert an extra space
                        my @output = `$nfdump -r /data/nfsen/profiles/live/$border/nfcapd.$timeslot -n 1 -s record/bytes -o "fmt:%ts %td %pr %sap -> %dap %pkt %byt %bps %in %out %sas %das %fl" '$modifiedIfType $if and net $prefix'`;

                        $bytes{$ifType} = 0;
                        if ( $output[-4] =~ /Summary: total flows: $bytes_string, total bytes: ($bytes_string), total packets:/ ) {
                            $bytes{$ifType} = $1;
                        }

                        # convert M & G to scalar values.
                        if ( $bytes{$ifType} =~ /[0-9]{1,}\.[0-9] M/ ) {    #we have bytes in M -> convert.
                            $bytes{$ifType} =~ s/M$//;                      #cut the M
                            $bytes{$ifType} = $bytes{$ifType} * 1000000;    #multiply by 1 milion
                        }
                        if ( $bytes{$ifType} =~ /[0-9]{1,}\.[0-9] G/ ) {    #we have bytes in G -> convert.
                            $bytes{$ifType} =~ s/G$//;                      #cut the G
                            $bytes{$ifType} = $bytes{$ifType} * 1000000000; #multiply by 1000 milion
                        }

                        #correct by the sampling rate, if we want to.
#                        $bytes{$ifType} *= $getConfig->( 'sampleRate', \%sources, $border ) if ( $getConfig->( 'multiplySamplingRate', \%sources, $border ) );
                    }
                    get_logger()->debug("Got inbound bytes=$bytes{'inif'}, outbound bytes=$bytes{'outif'}") if ( $bytes{'inif'} > 0 || $bytes{'outif'} > 0 );

                    # save the value(s) to do a top later, or draw global traffic statistics
                    if ( !defined $srcPrefixData{$border} ) {
                        $srcPrefixData{$border} = ();
                    }
                    my @interfaceType = $getConfig->( 'interfaceType', \%sources, $border, $if );
                    foreach my $ifType (@interfaceType) {
                        if ( !defined $srcPrefixData{$border}{$ifType} ) {

                            #save the value for later processing.
                            $srcPrefixData{$border}{$ifType} = ();
                        }
                        if ( !defined $srcPrefixData{$border}{$ifType}{$prefix} ) {
                            $srcPrefixData{$border}{$ifType}{$prefix} = $bytes{$ifType};
                        }
                        else {
                            $srcPrefixData{$border}{$ifType}{$prefix} += $bytes{$ifType};
                        }

                    }

                    if ( $getConfig->( 'drawOnlyTop20SrcPrefix', \%sources, $border ) ) {
                        next;
                    }
                    else {

                        #now that we have the value(s), update the rrd and png.
                        if ( !-d "$rrdPath/$border/$if" || !-d "$pictureDir/$border/$if" ) {
                            mkdir( "$rrdPath/$border",        0777 );
                            mkdir( "$rrdPath/$border/$if",    0777 );
                            mkdir( "$pictureDir/$border",     0777 );
                            mkdir( "$pictureDir/$border/$if", 0777 );

                            chmod 0775, "$pictureDir", "$pictureDir/$border", "$pictureDir/$border/$if";

                        }

                        my $need_to_update = 0;

                        #compute bps
                        my %bps;
                        foreach my $ifType ( keys %bytes ) {
                            $bps{$ifType} = $bytes{$ifType} * 8 / 300;

                            if ( $bps{$ifType} > 0 ) {
                                $need_to_update = 1;    #it means we have some traffic, and we need to update the graphs.
                            }
                        }

                        #if we have only one interface, we'll draw *ONLY* global graphs to reduce the overhead
                        my %interfaceDescriptions = $getConfig->( 'interfaces', \%sources, $border );
                        if ( scalar( keys %interfaceDescriptions ) == 1 ) {

                            #skip the next part
                        }
                        else {

                            my $filename = "srcpfx" . $prefix;
                            $filename =~ s/\//_/g;    #get rid of /

                            if ( !$need_to_update ) {

                                #there's no traffic for this prefix on this border/interface, so skip it.
                                next;
                            }
                            get_logger()->debug("Got inbound bytes=$bytes{'inif'}, outbound bytes=$bytes{'outif'}, inbound bps=$bps{'inif'}, outbound bps=$bps{'outif'}");
                            $rrdUpdate->( 'filename' => "$rrdPath/$border/$if/$filename.rrd", 'inif' => "$bps{'inif'}", 'outif' => "$bps{'outif'}", 'type' => '2bps' );

                            if ( !$drawGraphsOnRequest ) {

                                #draw png files while we're at it...
                                $rrdDraw->(
                                    'filename'    => "$rrdPath/$border/$if/$filename.rrd",
                                    'dstfile'     => "$pictureDir/$border/$if/$filename-daily.png",
                                    'destination' => "$pictureDir/$border/$if",
                                    'title'       => "Traffic for source $prefix (" . $interfaceDescriptions{$if} . " on $border)",
                                    'type'        => '2bps'
                                );

                            }    #else(!$drawGraphsOnRequest)
                        }    #else
                    }    #else $drawOnlyTop20SrcPrefix
                }    # foreach my $prefix

                ###########################################
                # gather (and draw) 'other' source prefix #
                ###########################################

                my %bytes;
                my $prefix = '0.0.0.0/0';                                                       #hardcoded convention
                my @interfaceType = $getConfig->( 'interfaceType', \%sources, $border, $if );
                foreach my $ifType (@interfaceType) {
                    get_logger()->debug("Parsing on $border, $ifType, interface $if, others (0.0.0.0/0)");

                    my @sourcesToIgnore = ();
                    if ( $getConfig->( 'drawOnlyTop20SrcPrefix', \%sources, $border ) ) {

                        #calculate top 20, and then see what's left.
                        #sort the hash
                        @sourcesToIgnore = sort { $srcPrefixData{$border}{$ifType}{$b} <=> $srcPrefixData{$border}{$ifType}{$a} } keys %{ $srcPrefixData{$border}{$ifType} };
                        splice( @sourcesToIgnore, 20 );                                         #truncate the array to 20 elements
                    }
                    else {

                        #draw from all.
                        @sourcesToIgnore = keys %{ $srcPrefixData{$border}{$ifType} };
                        splice( @sourcesToIgnore, 20 );                                         #truncate the array to 20 elements
                    }

                    my $query_string = '';
                    foreach my $pfx (@sourcesToIgnore) {
                        if ( $pfx eq '0.0.0.0/0' || $pfx eq '0.0.0.0/32' ) {
                            next;
                        }
                        else {
                            $query_string .= " and ! net $pfx";
                        }
                    }
                    get_logger()->debug("Query string: $query_string");

                    #now we need to parse the flows and see if we get anything.
                    my $modifiedIfType = $ifType;
                    $modifiedIfType =~ s/if/ if/;    #insert an extra space
                    my @output = `$nfdump -r /data/nfsen/profiles/live/$border/nfcapd.$timeslot -n 1 -s record/bytes -o "fmt:%ts %td %pr %sap -> %dap %pkt %byt %bps %in %out %sas %das %fl" '$modifiedIfType $if $query_string'`;

                    $bytes{$ifType} = 0;
                    if ( $output[-4] =~ /Summary: total flows: $bytes_string, total bytes: ($bytes_string), total packets:/ ) {
                        $bytes{$ifType} = $1;
                    }

                    # convert M & G to scalar values.
                    if ( $bytes{$ifType} =~ /[0-9]{1,}\.[0-9] M/ ) {    #we have bytes in M -> convert.
                        $bytes{$ifType} =~ s/M$//;                      #cut the M
                        $bytes{$ifType} = $bytes{$ifType} * 1000000;    #multiply by 1 milion
                    }
                    if ( $bytes{$ifType} =~ /[0-9]{1,}\.[0-9] G/ ) {    #we have bytes in G -> convert.
                        $bytes{$ifType} =~ s/G$//;                      #cut the G
                        $bytes{$ifType} = $bytes{$ifType} * 1000000000; #multiply by 1000 milion
                    }

                    #correct by the sampling rate, if we want to.
#                    $bytes{$ifType} *= $getConfig->( 'sampleRate', \%sources, $border ) if ( $getConfig->( 'multiplySamplingRate', \%sources, $border ) );

                    get_logger()->debug("Got inbound bytes=$bytes{'inif'}, outbound bytes=$bytes{'outif'}") if ( $bytes{'inif'} > 0 || $bytes{'outif'} > 0 );

                    # save the value(s) to draw global traffic statistics
                    if ( !defined $srcPrefixData{$border} ) {
                        $srcPrefixData{$border} = ();
                    }

                    if ( !defined $srcPrefixData{$border}{$ifType} ) {

                        #save the value for later processing.
                        $srcPrefixData{$border}{$ifType} = ();
                    }
                    if ( !defined $srcPrefixData{$border}{$ifType}{$prefix} ) {
                        $srcPrefixData{$border}{$ifType}{$prefix} = $bytes{$ifType};
                    }
                    else {
                        $srcPrefixData{$border}{$ifType}{$prefix} += $bytes{$ifType};
                    }
                }    #foreach my $ifType

                #now that we have the value(s), update the rrd and png.
                if ( !-d "$rrdPath/$border/$if" || !-d "$pictureDir/$border/$if" ) {
                    mkdir( "$rrdPath/$border",        0777 );
                    mkdir( "$rrdPath/$border/$if",    0777 );
                    mkdir( "$pictureDir/$border",     0777 );
                    mkdir( "$pictureDir/$border/$if", 0777 );
                    chmod 0775, "$pictureDir", "$pictureDir/$border", "$pictureDir/$border/$if";
                }

                my $need_to_update = 0;

                #compute bps
                my %bps;
                my @interfaceType = $getConfig->( 'interfaceType', \%sources, $border, $if );
                foreach my $ifType (@interfaceType) {
                    $bps{$ifType} = $bytes{$ifType} * 8 / 300;

                    if ( $bps{$ifType} > 0 ) {
                        $need_to_update = 1;    #it means we have some traffic, and we need to update the graphs.
                    }
                }

                #if we have only one interface, we'll draw *ONLY* global graphs to reduce the overhead
                my %interfaceDescriptions = $getConfig->( 'interfaces', \%sources, $border );
                if ( scalar( keys %interfaceDescriptions ) == 1 ) {

                    #skip the next part
                }
                else {

                    my $filename = "srcpfx" . $prefix;
                    $filename =~ s/\//_/g;    #get rid of /

                    if ( !$need_to_update ) {

                        #there's no traffic for this prefix on this border/interface, so skip it.
                        next;
                    }
                    get_logger()->debug("Got inbound bytes=$bytes{'inif'}, outbound bytes=$bytes{'outif'}, inbound bps=$bps{'inif'}, outbound bps=$bps{'outif'}");
                    $rrdUpdate->( 'filename' => "$rrdPath/$border/$if/$filename.rrd", 'inif' => "$bps{'inif'}", 'outif' => "$bps{'outif'}", 'type' => '2bps' );
                    if ( !$drawGraphsOnRequest ) {

                        #draw png files while we're at it...
                        $rrdDraw->(
                            'filename'    => "$rrdPath/$border/$if/$filename.rrd",
                            'dstfile'     => "$pictureDir/$border/$if/$filename-daily.png",
                            'destination' => "$pictureDir/$border/$if",
                            'title'       => "Traffic for source $prefix (" . $interfaceDescriptions{$if} . " on $border)",
                            'type'        => '2bps'
                        );

                    }    #else(!$drawGraphsOnRequest)
                }    #else (scalar (keys...))
            }    #if(scalar(@{$srcPrefix{$border}}))

            my %interfaceDescriptions = $getConfig->( 'interfaces', \%sources, $border );

            #####################################
            # draw traffic per AS per interface #
            #####################################

            #process AS per border and per interface
            my %AStype = $getConfig->( 'ifASType', \%sources, $border, $if );
            if ( $process{'as'} == 1 && ( ( defined $AStype{'src as'} && $AStype{'src as'} > 0 ) || ( defined $AStype{'dst as'} && $AStype{'dst as'} > 0 ) ) ) {
                foreach my $target ( keys %AStype ) {

                    #we want to get an accurate nr of ASes per interface, so we will do a top X AS per interface.
                    #these ASes will populate $ASes{$border}

                    ############################################
                    # generating top X src/dstAS per interface #
                    ############################################

                    my $condensedTarget = $target;
                    $condensedTarget =~ s/\s+//g;

                    if ($ASEfficiency) {
                        my @interfaceType = $getConfig->( 'interfaceType', \%sources, $border, $if );
                        foreach my $ifType (@interfaceType) {
                            get_logger()->debug("Getting top $AStype{$target} for $border on if $if");
                            my $modifiedIfType = $ifType;
                            $modifiedIfType =~ s/if/ if/;    #insert an extra space
                            my @output = `$nfdump -r /data/nfsen/profiles/live/$border/nfcapd.$timeslot -n $AStype{$target} -s $condensedTarget/bytes -o extended '$modifiedIfType $if'`;
                            foreach my $line (@output) {
#                                if ( $line =~ /^$date_time_string\s+$duration_string\s+$proto_string\s+($dst_as_string)\s+$flows_string\s+$packets_string\s+($bytes_string)\s+$pps_string\s+$bps_string\s+$bpp_string$/ ) {
				 if ( $line =~ /^$date_time_string\s+$duration_string\s+$proto_string\s+($dst_as_string)\s+$flows_string(?:\([0-9\.\s]+\))?\s+$packets_string(?:\([0-9\.\s]+\))?\s+($bytes_string)(?:\([0-9\.\s]+\))?\s+$pps_string\s+$bps_string\s+$bpp_string$/ ) {
#Date first seen          Duration Proto            Src AS    Flows(%)     Packets(%)       Bytes(%)         pps      bps   bpp
#2010-07-30 11:55:52.460   830.093 any                   0    47871(93.0)  103.6 M(93.2)   88.1 G(95.1)   124753  849.1 M   850

                                    my $dst_as = $1;
                                    if ( $dst_as eq "0" && $condensedTarget eq 'dstas' ) {
                                        $dst_as = $getConfig->( 'personalAS', \%sources, $border );    #set manually.
                                    }

                                    ##if the AS is already known, no need to add it again.
                                    #next if ( defined $ASes{$border}{ '' . $condensedTarget . $dst_as } );

                                    my $as_bytes = $2;
                                    if ( $as_bytes =~ /[0-9]{1,}\.[0-9] M/ ) {                         #we have bytes in M -> convert.
                                        $as_bytes =~ s/M$//;                                           #cut the M
                                        $as_bytes = $as_bytes * 1000000;                               #multiply by 1 milion
                                    }
                                    if ( $as_bytes =~ /[0-9]{1,}\.[0-9] G/ ) {                         #we have bytes in G -> convert.
                                        $as_bytes =~ s/G$//;                                           #cut the G
                                        $as_bytes = $as_bytes * 1000000000;                            #multiply by 10^9
                                    }

                                    #record this AS for future.
                                    #if ( !defined $ASes{$border}{ '' . $condensedTarget . $dst_as } ) {

                                    #correct the value with sampling
#                                    $as_bytes *= $getConfig->( 'sampleRate', \%sources, $border ) if ( $getConfig->( 'multiplySamplingRate', \%sources, $border ) );
                                    $ASes{$border}{ '' . $condensedTarget . $dst_as }{$ifType} = $as_bytes;

                                    #}

                                }    #if $line=~//
                            }    #foreach my $line (@output);
                        }    #foreach my $ifType
                    }    #if ($ASEfficiency)
                    else {
                        get_logger()->debug("Getting top $AStype{$target} for $border on if $if");
                        my @output = `$nfdump -r /data/nfsen/profiles/live/$border/nfcapd.$timeslot -n $AStype{$target} -s $condensedTarget/bytes -o extended 'if $if'`;
                        foreach my $line (@output) {
                            if ( $line =~ /^$date_time_string\s+$duration_string\s+$proto_string\s+($dst_as_string)\s+$flows_string(?:\([0-9\.\s]+\))?\s+$packets_string(?:\([0-9\.\s]+\))?\s+($bytes_string)(?:\([0-9\.\s]+\))?\s+$pps_string\s+$bps_string\s+$bpp_string$/ ) {
#Date first seen          Duration Proto            Src AS    Flows(%)     Packets(%)       Bytes(%)         pps      bps   bpp
#2010-07-30 11:55:52.460   830.093 any                   0    47871(93.0)  103.6 M(93.2)   88.1 G(95.1)   124753  849.1 M   850

                                my $dst_as = $1;
                                if ( $dst_as eq "0" && $condensedTarget eq 'dstas' ) {
                                    $dst_as = $getConfig->( 'personalAS', \%sources, $border );    #set manually.
                                }

                                #if the AS is already known, no need to add it again.
                                next if ( defined $ASes{$border}{ '' . $condensedTarget . $dst_as } );

                                my $as_bytes = $2;
                                if ( $as_bytes =~ /[0-9]{1,}\.[0-9] M/ ) {                         #we have bytes in M -> convert.
                                    $as_bytes =~ s/M$//;                                           #cut the M
                                    $as_bytes = $as_bytes * 1000000;                               #multiply by 1 milion
                                }
                                if ( $as_bytes =~ /[0-9]{1,}\.[0-9] G/ ) {                         #we have bytes in G -> convert.
                                    $as_bytes =~ s/G$//;                                           #cut the G
                                    $as_bytes = $as_bytes * 1000000000;                            #multiply by 10^9
                                }

                                #record this AS for future.
                                if ( !defined $ASes{$border}{ '' . $condensedTarget . $dst_as } ) {

                                    $ASes{$border}{ '' . $condensedTarget . $dst_as }{inif}  = 0;
                                    $ASes{$border}{ '' . $condensedTarget . $dst_as }{outif} = 0;
                                }

                                #we do not save the actual value, because it will be computed later (for input & output traffic).
                                #now, we only need the AS number.

                            }    #if $line=~//
                        }    #foreach my $line (@output);
                    }    #else ($ASEfficiency)

                    #add a record for 'others', otherwise it's not processed.
                    if ( !defined $ASes{$border}{ '' . $condensedTarget . '65536' } ) {
                        $ASes{$border}{ '' . $condensedTarget . "65536" }{inif}  = 0;
                        $ASes{$border}{ '' . $condensedTarget . "65536" }{outif} = 0;
                    }

                    foreach my $as ( keys %{ $ASes{$border} } ) {
                        my $string = $target;
                        $string =~ s/\s+//;
                        $string = lc($string);

                        if ( $as !~ /$string/ ) {

                            #we're not looking now for this AS.
                            next;
                        }
                        else {

                            #this is an AS we need to process
                            $as =~ s/$string//;    #cut srcas from the string.
                        }

                        if ( $as == $getConfig->( 'personalAS', \%sources, $border ) && $target eq 'dst as' ) {

                            #temporarly change the as to 0 if it's my destination as.
                            #we'll change it back in a few lines.
                            $as = 0;
                            get_logger()->debug( "Changing dstas " . $getConfig->( 'personalAS', \%sources, $border ) . " to dstas 0 temporarly" );
                        }

                        if ( $as == 65536 ) {

                            #we need to process this one differently

                            get_logger()->debug("Parsing for $border, interface $if, AS $as, target $target (LOCAL OTHERS)");

                            #first, get a list of ASes we want to filter out.
                            #				my %list;
                            my $query_string = '';
                            foreach my $as2 ( keys %{ $ASes{$border} } ) {
                                if ( $as2 =~ /$string/ ) {
                                    $as2 =~ s/$string//;
                                    if ( $as2 == 65536 ) {

                                        #skip it
                                    }
                                    elsif ( $as2 == $getConfig->( 'personalAS', \%sources, $border ) && $target eq 'dst as' ) {

                                        #we need to change this one to AS0.
                                        $query_string .= " and ! $target 0";
                                    }
                                    else {

                                        #					    $list{$as}=0;
                                        $query_string .= " and ! $target $as2";
                                    }
                                }
                            }
                            get_logger()->debug("Query string: $query_string");

                            my %bytes;
                            my @interfaceType = $getConfig->( 'interfaceType', \%sources, $border, $if );
                            foreach my $ifType (@interfaceType) {

                   #get_logger()->debug("CMDLINE: $nfdump -r /data/nfsen/profiles/live/$border/nfcapd.$timeslot -n 1 -s record/bytes -o \"fmt:\%ts \%td \%pr \%sap -> \%dap \%pkt \%byt \%bps \%in \%out \%sas \%das \%fl\" '$ifType $if $query_string'");
                                my $modifiedIfType = $ifType;
                                $modifiedIfType =~ s/if/ if/;    #insert an extra space
                                my @output = `$nfdump -r /data/nfsen/profiles/live/$border/nfcapd.$timeslot -n 1 -s record/bytes -o "fmt:%ts %td %pr %sap -> %dap %pkt %byt %bps %in %out %sas %das %fl" '$modifiedIfType $if $query_string'`;

                                #my $output_string=join("\n", @output);
                                #get_logger()->debug('OUTPUT:'.$output_string);
                                $bytes{$ifType} = 0;

                                if ( $output[-4] =~ /Summary: total flows: $bytes_string, total bytes: ($bytes_string), total packets:/ ) {
                                    $bytes{$ifType} = $1;
                                }

                                # convert M & G to scalar values.
                                if ( $bytes{$ifType} =~ /[0-9]{1,}\.[0-9] M/ ) {    #we have bytes in M -> convert.
                                    $bytes{$ifType} =~ s/M$//;                      #cut the M
                                    $bytes{$ifType} = $bytes{$ifType} * 1000000;    #multiply by 1 milion
                                }
                                if ( $bytes{$ifType} =~ /[0-9]{1,}\.[0-9] G/ ) {    #we have bytes in G -> convert.
                                    $bytes{$ifType} =~ s/G$//;                      #cut the G
                                    $bytes{$ifType} = $bytes{$ifType} * 1000000000; #multiply by 1000 milion
                                }

                                #correct the values by multiplying with the sampling rate
#                                $bytes{$ifType} *= $getConfig->( 'sampleRate', \%sources, $border ) if ( $getConfig->( 'multiplySamplingRate', \%sources, $border ) );

                            }

                            #now that we have the value, update the rrd and png.
                            if ( !-d "$rrdPath/$border/$if" || !-d "$pictureDir/$border/$if" ) {
                                mkdir( "$rrdPath/$border",        0777 );
                                mkdir( "$rrdPath/$border/$if",    0777 );
                                mkdir( "$pictureDir/$border",     0777 );
                                mkdir( "$pictureDir/$border/$if", 0777 );

                                chmod 0775, "$pictureDir", "$pictureDir/$border", "$pictureDir/$border/$if";
                            }

                            my $need_to_update = 0;

                            #compute bps
                            my %bps;
                            foreach my $ifType ( keys %bytes ) {
                                $bps{$ifType} = $bytes{$ifType} * 8 / 300;
                                if ( $bps{$ifType} > 0 ) {
                                    $need_to_update = 1;    #it means we have some traffic, and we need to update the graphs.

                                    #we need to calculate global AS based on interface sum, save both 'inif' value and 'outif'
                                    my $string = $target;
                                    $string =~ s/\s+//;
                                    $string = lc($string);

                                    #the following exception applies: srcas 0 on outif is actually $personalAS
                                    if ( $as eq '0' && $string eq 'srcas' && $ifType eq 'outif' ) {
                                        $ASes{$border}{ $string . $getConfig->( 'personalAS', \%sources, $border ) }{$ifType} += $bytes{$ifType};

                                    }
                                    else {
                                        $ASes{$border}{ $string . $as }{$ifType} += $bytes{$ifType};
                                    }
                                    get_logger()->debug("AS$as, $string, border=$border, added $bytes{$ifType} bytes for interface $ifType $if");

                                }
                            }

                            my $direction = $target;
                            $direction =~ s/\s+//g;
                            $direction = lc($direction);

                            get_logger()->debug("Got inbound bytes=$bytes{'inif'}, outbound bytes=$bytes{'outif'}, inbound bps=$bps{'inif'}, outbound bps=$bps{'outif'}");
                            my %intDes = $getConfig->( 'interfaces', \%sources, $border );
                            if ( !$need_to_update || scalar( keys %intDes ) == 1 ) {

                                #there's no traffic for this AS on this border/interface, so skip it, or we have only one interface and we draw only global traffic.
                                next;
                            }
                        }    # if $as == 65536
                        else {

                            get_logger()->debug("Parsing for $border, interface $if, AS $as, target $target");
                            my %bytes;
                            if ($ASEfficiency) {

                                #my $condensedTarget = $target;
                                #$condensedTarget=~s/\s*//;
                                #we already have the values
                                if ( $as == 0 && $target eq 'dst as' ) {
                                    $as = $getConfig->( 'personalAS', \%sources, $border );
                                    get_logger()->debug("Changing dstas 0 back to dstas $as");
                                }

                                $bytes{'inif'}  = $ASes{$border}{ "$string" . "$as" }{'inif'};
                                $bytes{'outif'} = $ASes{$border}{ "$string" . "$as" }{'outif'};
                            }
                            else {

                                #we do the inefficient way -> parse
                                my @interfaceType = $getConfig->( 'interfaceType', \%sources, $border, $if );
                                foreach my $ifType (@interfaceType) {
                                    my $modifiedIfType = $ifType;
                                    $modifiedIfType =~ s/if/ if/;    #insert an extra space
                                    my @output = `$nfdump -r /data/nfsen/profiles/live/$border/nfcapd.$timeslot -n 1 -s record/bytes -o "fmt:%ts %td %pr %sap -> %dap %pkt %byt %bps %in %out %sas %das %fl" '$modifiedIfType $if and $target $as'`;
                                    if ( $as == 0 && $target eq 'dst as' ) {
                                        $as = $getConfig->( 'personalAS', \%sources, $border );
                                        get_logger()->debug("Changing dstas 0 back to dstas $as");
                                    }
                                    $bytes{$ifType} = 0;

                                    if ( $output[-4] =~ /Summary: total flows: $bytes_string, total bytes: ($bytes_string), total packets:/ ) {
                                        $bytes{$ifType} = $1;
                                    }

                                    # convert M & G to scalar values.
                                    if ( $bytes{$ifType} =~ /[0-9]{1,}\.[0-9] M/ ) {    #we have bytes in M -> convert.
                                        $bytes{$ifType} =~ s/M$//;                      #cut the M
                                        $bytes{$ifType} = $bytes{$ifType} * 1000000;    #multiply by 1 milion
                                    }
                                    if ( $bytes{$ifType} =~ /[0-9]{1,}\.[0-9] G/ ) {    #we have bytes in G -> convert.
                                        $bytes{$ifType} =~ s/G$//;                      #cut the G
                                        $bytes{$ifType} = $bytes{$ifType} * 1000000000; #multiply by 1000 milion
                                    }

                                    #correct the values by multiplying with the sampling rate
#                                    $bytes{$ifType} *= $getConfig->( 'sampleRate', \%sources, $border ) if ( $getConfig->( 'multiplySamplingRate', \%sources, $border ) );
                                }
                            }

                            #now that we have the value, update the rrd and png.
                            if ( !-d "$rrdPath/$border/$if" || !-d "$pictureDir/$border/$if" ) {
                                mkdir( "$rrdPath/$border",        0777 );
                                mkdir( "$rrdPath/$border/$if",    0777 );
                                mkdir( "$pictureDir/$border",     0777 );
                                mkdir( "$pictureDir/$border/$if", 0777 );

                                chmod 0775, "$pictureDir", "$pictureDir/$border", "$pictureDir/$border/$if";
                            }

                            my $need_to_update = 0;

                            #compute bps
                            my %bps;
                            foreach my $ifType ( keys %bytes ) {
                                $bps{$ifType} = $bytes{$ifType} * 8 / 300;    #convert bytes/5min to bps
                                if ( $bps{$ifType} > 0 ) {
                                    $need_to_update = 1;                      #it means we have some traffic, and we need to update the graphs.

                                    #we need to calculate global AS based on interface sum, save both 'inif' value and 'outif'
                                    my $string = $target;
                                    $string =~ s/\s+//;
                                    $string = lc($string);

                                    #
                                    # %ASes keep the local data (per interface!) in bytes
                                    #

                                    #$ASes{$border}{ $string . $as }{$ifType} += $bytes{$ifType};

                                    #
                                    # %ASesTotal keep the global data (per router) in bytes
                                    #

                                    $ASesTotal{$border}{ $string . $as }{$ifType} = 0 if ( !defined $ASesTotal{$border}{ $string . $as }{$ifType} );
                                    $ASesTotal{$border}{ $string . $as }{$ifType} += $bytes{$ifType};

                                    get_logger()->debug("AS$as, $string, border=$border, added $bytes{$ifType} bytes for interface $ifType $if");

                                }
                            }

                            my $direction = $target;
                            $direction =~ s/\s+//g;
                            $direction = lc($direction);

                            #                        $direction =~ s/as/AS/;
                            #my $filename = "$direction$as";

                            #		$filename=~s/\//_/g; #get rid of /
                            my %intDes = $getConfig->( 'interfaces', \%sources, $border );
                            if ( !$need_to_update || scalar( keys %intDes ) == 1 ) {

                                #there's no traffic for this AS on this border/interface, so skip it, or we have only one interface and we draw only global graphs
                                next;
                            }
                            get_logger()->debug("Got inbound bytes=$bytes{'inif'}, outbound bytes=$bytes{'outif'}, inbound bps=$bps{'inif'}, outbound bps=$bps{'outif'}");

                        }    #else (! 65536)
                    }    #foreach my as
                }    #foreach my $target

                ########################################################
                # Update the rrds here (because of the new convention) #
                ########################################################

                #first, create a hash with the as numbers
                get_logger()->debug("Writing the values to rrd for border $border and interface $if");

                my %intDes = $getConfig->( 'interfaces', \%sources, $border );
                if ( scalar( keys %intDes ) == 1 ) {

                    #there's no traffic for this AS on this border/interface, so skip it, or we have only one interface and we draw only global graphs
                }
                else {

                    #srcas0 + outif => srcas$personalAS, outif
                    if ( defined $ASes{$border}{srcas0}{outif} ) {
                        $ASes{$border}{ 'srcas' . $getConfig->( 'personalAS', \%sources, $border ) }{outif} = $ASes{$border}{srcas0}{outif};
                        $ASes{$border}{srcas0}{outif} = 0;
                    }

                    #dstas0 + inif   => dstas$personalAS, inif
                    if ( defined $ASes{$border}{dstas0}{inif} ) {
                        $ASes{$border}{ 'dstas' . $getConfig->( 'personalAS', \%sources, $border ) }{inif} = $ASes{$border}{dstas0}{inif};
                        $ASes{$border}{dstas0} = 0;
                    }

                    my %participatingASes;
                    foreach my $as ( keys %{ $ASes{$border} } ) {
                        my $asn = $as;
                        $asn =~ s/...as//;
                        $participatingASes{$asn} = 1;
                    }

                    #go through the list of ASNumbers and save them to rrd
                    foreach my $asn ( keys %participatingASes ) {
                        my %inas;
                        $inas{inif}  = $ASes{$border}{"dstas${asn}"}{inif}  || 0;
                        $inas{outif} = $ASes{$border}{"srcas${asn}"}{outif} || 0;

                        my %outas;
                        $outas{inif}  = $ASes{$border}{"srcas${asn}"}{inif}  || 0;
                        $outas{outif} = $ASes{$border}{"dstas${asn}"}{outif} || 0;

                        #BEWARE: %ASes store the values in bytes! We need to convert them...
                        $inas{inif}   *= 8 / 300;
                        $inas{outif}  *= 8 / 300;
                        $outas{inif}  *= 8 / 300;
                        $outas{outif} *= 8 / 300;

                        #update the rrds for inas or outas (we shouldn't see both at the same time)
                        if ( $inas{inif} > $getConfig->( 'spoofThreshold', \%sources, $border ) || $inas{outif} > $getConfig->( 'spoofThreshold', \%sources, $border ) ) {
                            my $filename = "inas$asn";
                            get_logger->debug("$border: $if: Updating rrd ($filename) for as $asn as inas with values inif=$inas{inif} and outif=$inas{outif}");
                            $rrdUpdate->( 'filename' => "$rrdPath/$border/$if/$filename.rrd", 'inif' => $inas{inif}, 'outif' => $inas{outif}, 'type' => '2bps' );

                            if ( !$drawGraphsOnRequest ) {

                                #draw png files while we're at it...
                                $rrdDraw->(
                                    'filename'    => "$rrdPath/$border/$if/$filename.rrd",
                                    'dstfile'     => "$pictureDir/$border/$if/$filename-daily.png",
                                    'destination' => "$pictureDir/$border/$if",
                                    'title'       => "Traffic for AS$asn (" . $intDes{$if} . " on $border)",
                                    'type'        => '2bps'
                                );
                            }    #if(!$drawGraphsOnRequest)
                        }    #if($inas...)

                        if ( $outas{inif} > $getConfig->( 'spoofThreshold', \%sources, $border ) || $outas{outif} > $getConfig->( 'spoofThreshold', \%sources, $border ) ) {
                            my $filename = "outas$asn";
                            get_logger->debug("$border: $if: Updating rrd ($filename) for as $asn as outas with values inif=$outas{inif} and outif=$outas{outif}");
                            $rrdUpdate->( 'filename' => "$rrdPath/$border/$if/$filename.rrd", 'inif' => $outas{inif}, 'outif' => $outas{outif}, 'type' => '2bps' );

                            if ( !$drawGraphsOnRequest ) {

                                #draw png files while we're at it...
                                $rrdDraw->(
                                    'filename'    => "$rrdPath/$border/$if/$filename.rrd",
                                    'dstfile'     => "$pictureDir/$border/$if/$filename-daily.png",
                                    'destination' => "$pictureDir/$border/$if",
                                    'title'       => "Traffic for AS$asn (" . $intDes{$if} . " on $border)",
                                    'type'        => '2bps'
                                );
                            }    #if(!$drawGraphsOnRequest)
                        }    #if($outas...
                    }    #foreach my $asn (keys %participatingASes)
                }    #else not one interface
            }    #if ($process{'as'}==1)

            ######################################
            # gather top X sources per interface #
            ######################################

            get_logger()->debug( "Ready to gather top " . $getConfig->( 'drawTopXSources', \%sources, $border ) . " (or ". $getConfig->( 'drawTopXSources', \%sources, $border, $if ). ") source IPs" );

            if ( $getConfig->( 'drawTopXSources', \%sources, $border ) > 0 || $getConfig->( 'drawTopXSources', \%sources, $border, $if ) > 0) {

                #gather statistics
		my $topXSources = $getConfig->( 'drawTopXSources', \%sources, $border, $if );
		if(! defined $topXSources){
		    #if not defined, override with the border setting
		    $topXSources = $getConfig->( 'drawTopXSources', \%sources, $border );
		}
                get_logger()->debug( "Gathering top " . $topXSources . " source IPs from $border, on interface $if" );
                my %bytes;
                my @interfaceType = $getConfig->( 'interfaceType', \%sources, $border, $if );
                foreach my $ifType (@interfaceType) {
                    
                    my $modifiedIfType = $ifType;
                    $modifiedIfType =~ s/if/ if/;    #insert an extra space
                    my @output   = `$nfdump -r /data/nfsen/profiles/live/$border/nfcapd.$timeslot -n $topXSources -s record/bytes -A srcip -o "fmt:%ts %td %pr %sap -> %dap %pkt %byt %bps %in %out %sas %das %fl" '$modifiedIfType $if'`;
                    my @prefixes = ();
                    foreach my $line (@output) {

                        if ( $line =~ /$date_time_string\s+$duration_string\s+$proto_string\s+($src_ip_string):$src_port_string\s+->\s+$dst_ip_string:$dst_port_string\s+$packets_string\s+($bytes_string)\s+$bps_string/ ) {
                            my $ip     = $1;
                            my $prefix = $ip . "/32";
                            push @prefixes, $prefix;
                            $bytes{$ip} = ();
                            $bytes{$ip}{$ifType} = $2;

                            # convert M & G to scalar values.
                            if ( $bytes{$ip}{$ifType} =~ /[0-9]{1,}\.[0-9] M/ ) {    #we have bytes in M -> convert.
                                $bytes{$ip}{$ifType} =~ s/M$//;                      #cut the M
                                $bytes{$ip}{$ifType} = $bytes{$ip}{$ifType} * 1000000;    #multiply by 1 milion
                            }
                            if ( $bytes{$ip}{$ifType} =~ /[0-9]{1,}\.[0-9] G/ ) {         #we have bytes in G -> convert.
                                $bytes{$ip}{$ifType} =~ s/G$//;                           #cut the G
                                $bytes{$ip}{$ifType} = $bytes{$ip}{$ifType} * 1000000000; #multiply by 1000 milion
                            }

                            #correct by the sampling rate, if we want to.
#                            $bytes{$ip}{$ifType} *= $getConfig->( 'sampleRate', \%sources, $border ) if ( $getConfig->( 'multiplySamplingRate', \%sources, $border ) );
                            get_logger()->debug("Found $ip with $bytes{$ip}{$ifType} bytes with type $ifType");

                            if ( !defined $srcIPData{$border} ) {
                                $srcIPData{$border} = ();
                            }
                            if ( !defined $srcIPData{$border}{$ifType} ) {

                                #save the value for later processing.
                                $srcIPData{$border}{$ifType} = ();
                            }
                            if ( !defined $srcIPData{$border}{$ifType}{$prefix} ) {
                                $srcIPData{$border}{$ifType}{$prefix} = $bytes{$ip}{$ifType} * 8 / 300;
                            }
                            else {
                                $srcIPData{$border}{$ifType}{$prefix} += $bytes{$ip}{$ifType} * 8 / 300;
                            }
                            get_logger()->debug("Saved $ip with $srcIPData{$border}{$ifType}{$prefix} bps ($bytes{$ip}{$ifType} bytes) with type $ifType");
                        }    #if($line=~//)
                        if ( $line =~ /Summary: total flows: $bytes_string, total bytes: ($bytes_string), total packets:/ ) {

                            # record the rest of the values from the summary.
                            # the summary holds the total, so we have to deduct the values already read.
                            get_logger()->debug("Gathering 'others' for source prefix on border $border, $ifType.");

                            my $total_bytes = $1;
                            if ( $total_bytes =~ /[0-9]{1,}\.[0-9] M/ ) {    #we have bytes in M -> convert.
                                $total_bytes =~ s/M$//;                      #cut the M
                                $total_bytes = $total_bytes * 1000000;       #multiply by 1 milion
                            }
                            if ( $total_bytes =~ /[0-9]{1,}\.[0-9] G/ ) {    #we have bytes in G -> convert.
                                $total_bytes =~ s/G$//;                      #cut the G
                                $total_bytes = $total_bytes * 1000000000;    #multiply by 10^9
                            }

                            #correct by the sampling rate, if it's desired.
#                            $srcIPData{$border}{$ifType}{ '' . '0.0.0.0/32' } *= $getConfig->( 'sampleRate', \%sources, $border ) if ( $getConfig->( 'multiplySamplingRate', \%sources, $border ) );

                            #record the corrected value
                            my $difference = 0;
                            foreach my $srcpfx (@prefixes) {
                                $srcpfx =~ s/\/32//;
                                $difference += $bytes{$srcpfx}{$ifType};
                            }

                            $total_bytes -= $difference;

                            # to prevent negative traffic set the total traffic to 0
                            # this would happen when all your prefixes are included in top 10, and the difference is negative because of
                            # approximations.
                            $total_bytes = 0 if ( $total_bytes < 0 );

                            #save the corrected value
                            #the convention is that the 'other' value will be 0.0.0.0/32 for src and dst hosts.
                            $srcIPData{$border}{$ifType}{ '' . '0.0.0.0/32' } = $total_bytes;
                            get_logger()->debug("Saving '0.0.0.0/32' $ifType with value $total_bytes (difference was $difference)");

                            #convert it to bps
                            $srcIPData{$border}{$ifType}{ '' . '0.0.0.0/32' } *= 8 / 300;

                        }    #if $line=~/Summary/
                    }    #foreach my $line.
                         #we don't graph per interface, but if we'll need it, we can add it here.
                         
                         
                    ############################################
                    # draw top X sources graphic per interface #
                    ############################################        
                    
                    ###################
                    # BUG: TO BE FIXED: The data is stored globally per router, not per interface - and gets incremented
                    # Will generate false data if more than one interface per router has topXSources active!
                    ###################
                    if(defined $getConfig->( 'drawTopXSources', \%sources, $border, $if ) ){
                        get_logger()->debug( "Ready to graph top " . $topXSources . " sources for interface $if" );

                        if ( $topXSources > 0 ) {
                            my %intDes = $getConfig->( 'interfaces', \%sources, $border );
                            get_logger()->debug("We are going to graph these sources for ifType $ifType.");
                            
                            foreach my $prefix ( keys %{ $srcIPData{$border}{$ifType} } ) {
                                get_logger()->debug("Drawing graph for source host $prefix on $border, type $ifType with $srcIPData{$border}{$ifType}{$prefix} bps");

                                #draw the graphs for this one.

                                my $filename = "srcpfx" . $prefix;
                                $filename =~ s/\//_/g;    #get rid of /

                                #kind of hardcoded, but should work...
                                if ( $ifType eq 'inif' ) {
                                    $rrdUpdate->( 'filename' => "$rrdPath/$border/$if/$filename.rrd", 'inif' => $srcIPData{$border}{'inif'}{$prefix}, 'type' => '2bps' );
                                }
                                else {
                                    $rrdUpdate->( 'filename' => "$rrdPath/$border/$if/$filename.rrd", 'outif' => $srcIPData{$border}{'outif'}{$prefix}, 'type' => '2bps' );
                                }

                                #we have updated the rrd (hopefully).

                                if ( !$drawGraphsOnRequest ) {

                                    #draw png files while we're at it...
                                    $rrdDraw->(
                                        'filename'    => "$rrdPath/$border/$if/$filename.rrd",
                                        'dstfile'     => "$pictureDir/$border/$if/$filename-daily.png",
                                        'destination' => "$pictureDir/$border/$if",
                                        'title'       => "Traffic for source $prefix (".$intDes{$if}." on $border)",
                                        'type'        => '2bps'
                                    );

                                }    #if(!drawGraphsOnRequest)
                            }    # foreach my $prefix
                           
                        }    # if($drawTopXSources{$border})
                         
                    }  #if going to graph          
                         
                }    #foreach my $ifType
            }    # if($drawTopXSources...)

        }    #foreach my if

        ####################################
        # done processing interface status #
        ####################################

        ##################################
        # draw prefix graphic per border #
        ##################################

        if ( $process{'prefix'} == 1 ) {

            #for every border draw total traffic graphs for prefixes.
            foreach my $prefix ( keys %borderBPS ) {
                my $need_to_upgrade = 0;
                foreach my $ifType ( keys %{ $borderBPS{$prefix} } ) {
                    if ( $borderBPS{$prefix}{$ifType} > 0 ) {
                        $need_to_upgrade = 1;
                    }
                }
                if ( !$need_to_upgrade ) {
                    next;    #skip it
                }
                get_logger()->debug("Parsing for $border, prefix $prefix");
                get_logger()->debug("Got inbound bps=$borderBPS{$prefix}{'inif'}, outbound bps=$borderBPS{$prefix}{'outif'}");

                my $filename = $prefix;
                $filename =~ s/\//_/g;    #get rid of /

                $rrdUpdate->( 'filename' => "$rrdPath/$border/$filename.rrd", 'inif' => "$borderBPS{$prefix}{'inif'}", 'outif' => "$borderBPS{$prefix}{'outif'}", 'type' => '2bps' );
                if ( !$drawGraphsOnRequest ) {

                    #draw png files while we're at it...
                    $rrdDraw->( 'filename' => "$rrdPath/$border/$filename.rrd", 'dstfile' => "$pictureDir/$border/$filename-daily.png", 'destination' => "$pictureDir/$border", 'title' => "Traffic for $prefix (on $border)", 'type' => '2bps' );

                }                         #if(!drawGraphsOnRequest)
            }    #foreach my prefix (global - on border).
        }    #if($process{'prefix'}==1)

        #################################
        # draw source prefix per border #
        #################################

        if ( $getConfig->( 'drawOnlyTop20SrcPrefix', \%sources, $border ) ) {

            #first, calculate top20.

            foreach my $ifType (qw(inif outif)) {

                #sort the hash
                my @sorted = ();

                @sorted = sort { $srcPrefixData{$border}{$ifType}{$b} <=> $srcPrefixData{$border}{$ifType}{$a} } keys %{ $srcPrefixData{$border}{$ifType} };
                for ( my $i = 0 ; $i < scalar(@sorted) ; $i++ ) {
                    if ( $sorted[$i] eq '0.0.0.0/0' ) {

                        #make sure we don't get 0.0.0.0/0 again in the top, because we'll have problems when generating the rrd.
                        splice( @sorted, $i, 1 );
                    }
                }

                #see if sorted has any elements. If we're monitoring outif and we don't have any exports on outif, @sorted will be empty.

                unshift @sorted, '0.0.0.0/0' if ( scalar @sorted );    #make sure we save it, if sorted contains anything. Else, forget about it.

                for ( my $i = 0 ; $i < 21 && $i < scalar(@sorted) ; $i++ ) {
                    get_logger()->debug( "Top $i $ifType on $border: $sorted[$i] with " . $srcPrefixData{$border}{$ifType}{ $sorted[$i] } );

                    #draw the graphs for this one.

                    my $filename = "srcpfx" . $sorted[$i];
                    my $prefix   = $sorted[$i];
                    $filename =~ s/\//_/g;                             #get rid of /

                    #kind of hardcoded, but should work...
                    if ( $ifType eq 'inif' ) {
                        $rrdUpdate->( 'filename' => "$rrdPath/$border/$filename.rrd", 'inif' => $srcPrefixData{$border}{'inif'}{ $sorted[$i] } * 8 / 300, 'type' => '2bps' );
                    }
                    else {
                        $rrdUpdate->( 'filename' => "$rrdPath/$border/$filename.rrd", 'outif' => $srcPrefixData{$border}{'outif'}{ $sorted[$i] } * 8 / 300, 'type' => '2bps' );
                    }

                    #we have updated the rrd (hopefully).

                    if ( !$drawGraphsOnRequest ) {

                        #draw png files while we're at it...
                        $rrdDraw->(
                            'filename'    => "$rrdPath/$border/$filename.rrd",
                            'dstfile'     => "$pictureDir/$border/$filename-daily.png",
                            'destination' => "$pictureDir/$border",
                            'title'       => "Traffic for source $prefix (on $border)",
                            'type'        => '2bps'
                        );

                    }    #if(!drawGraphsOnRequest)
                }    # for(my $i=0; $i<20 && $i<scalar(@sorted); $i++){
            }    # foreach my $ifType
        }    # if( $drawOnlyTop20SrcPrefix ){
        else {

            #draw all
            foreach my $ifType (qw(inif outif)) {
                foreach my $prefixes ( keys %{ $srcPrefixData{$border}{$ifType} } ) {
                    get_logger()->debug( "Updating rrd for $ifType on $border: $prefixes with " . $srcPrefixData{$border}{$ifType}{$prefixes} );

                    #draw the graphs for this one.

                    my $filename = "srcpfx" . $prefixes;
                    my $prefix   = $prefixes;
                    $filename =~ s/\//_/g;    #get rid of /

                    #kind of hardcoded, but should work...
                    if ( $ifType eq 'inif' ) {
                        $rrdUpdate->( 'filename' => "$rrdPath/$border/$filename.rrd", 'inif' => $srcPrefixData{$border}{'inif'}{$prefixes} * 8 / 300, 'type' => '2bps' );
                    }
                    else {
                        $rrdUpdate->( 'filename' => "$rrdPath/$border/$filename.rrd", 'outif' => $srcPrefixData{$border}{'outif'}{$prefixes} * 8 / 300, 'type' => '2bps' );
                    }

                    #we have updated the rrd (hopefully).
                    if ( !$drawGraphsOnRequest ) {

                        #draw png files while we're at it...
                        $rrdDraw->(
                            'filename'    => "$rrdPath/$border/$filename.rrd",
                            'dstfile'     => "$pictureDir/$border/$filename-daily.png",
                            'destination' => "$pictureDir/$border",
                            'title'       => "Traffic for source $prefix (on $border)",
                            'type'        => '2bps'
                        );

                    }    #if(!drawGraphsOnRequest)
                }
            }
        }

        #########################################
        # draw top X sources graphic per border #
        #########################################

        get_logger()->debug( "Ready to graph top " . $getConfig->( 'drawTopXSources', \%sources, $border ) . " sources" );

        if ( $getConfig->( 'drawTopXSources', \%sources, $border ) > 0 ) {

            #for every border draw total traffic graphs for top 10 sources.
            get_logger()->debug("We are going to graph these sources.");
            foreach my $ifType (qw(inif outif)) {
                get_logger()->debug("Working for ifType $ifType");
                foreach my $prefix ( keys %{ $srcIPData{$border}{$ifType} } ) {
                    get_logger()->debug("Drawing graph for source host $prefix on $border, type $ifType with $srcIPData{$border}{$ifType}{$prefix} bps");

                    #draw the graphs for this one.

                    my $filename = "srcpfx" . $prefix;
                    $filename =~ s/\//_/g;    #get rid of /

                    #kind of hardcoded, but should work...
                    if ( $ifType eq 'inif' ) {
                        $rrdUpdate->( 'filename' => "$rrdPath/$border/$filename.rrd", 'inif' => $srcIPData{$border}{'inif'}{$prefix}, 'type' => '2bps' );
                    }
                    else {
                        $rrdUpdate->( 'filename' => "$rrdPath/$border/$filename.rrd", 'outif' => $srcIPData{$border}{'outif'}{$prefix}, 'type' => '2bps' );
                    }

                    #we have updated the rrd (hopefully).

                    if ( !$drawGraphsOnRequest ) {

                        #draw png files while we're at it...
                        $rrdDraw->(
                            'filename'    => "$rrdPath/$border/$filename.rrd",
                            'dstfile'     => "$pictureDir/$border/$filename-daily.png",
                            'destination' => "$pictureDir/$border",
                            'title'       => "Traffic for source $prefix (on $border)",
                            'type'        => '2bps'
                        );

                    }    #if(!drawGraphsOnRequest)
                }    # foreach my $prefix
            }    # foreach my $ifType (@interfaceType)
        }    # if($drawTopXSources{$border})

        ##############################
        # draw AS graphic per border #
        ##############################

        if ( $process{'as'} == 1 ) {

            #These values are calculated from the sum of the interface traffic.

            #first, create a hash with the as numbers
            get_logger()->debug("Writing the values to rrd for border $border");

            #srcas0 + outif => srcas$personalAS, outif
            if ( defined $ASesTotal{$border}{srcas0}{outif} ) {
                $ASesTotal{$border}{ 'srcas' . $getConfig->( 'personalAS', \%sources, $border ) }{outif} = $ASesTotal{$border}{srcas0}{outif};
                $ASesTotal{$border}{srcas0}{outif} = 0;
            }

            #dstas0 + inif   => dstas$personalAS, inif
            if ( defined $ASesTotal{$border}{dstas0}{inif} ) {
                $ASesTotal{$border}{ 'dstas' . $getConfig->( 'personalAS', \%sources, $border ) }{inif} = $ASesTotal{$border}{dstas0}{inif};
                $ASesTotal{$border}{dstas0} = 0;
            }

            my %participatingASes;
            foreach my $as ( keys %{ $ASesTotal{$border} } ) {
                my $asn = $as;
                $asn =~ s/...as//;
                $participatingASes{$asn} = 1;
            }

            #go through the list of ASNumbers and save them to rrd
            foreach my $asn ( keys %participatingASes ) {
                my %inas;
                $inas{inif}  = $ASesTotal{$border}{"dstas${asn}"}{inif}  || 0;
                $inas{outif} = $ASesTotal{$border}{"srcas${asn}"}{outif} || 0;

                my %outas;
                $outas{inif}  = $ASesTotal{$border}{"srcas${asn}"}{inif}  || 0;
                $outas{outif} = $ASesTotal{$border}{"dstas${asn}"}{outif} || 0;

                #convert to bps, because ASesTotal stores data in bytes
                foreach my $ifType ( 'inif', 'outif' ) {
                    $inas{$ifType}  *= 8 / 300;
                    $outas{$ifType} *= 8 / 300;
                }

                #update the rrds for inas or outas (we shouldn't see both at the same time)
                if ( $inas{inif} > $getConfig->( 'spoofThreshold', \%sources, $border ) || $inas{outif} > $getConfig->( 'spoofThreshold', \%sources, $border ) ) {
                    my $filename = "inas$asn";    # update just outbound, if it exists
                    get_logger->debug("$border: global: Updating rrd ($filename) for as $asn as inas with inif=$inas{inif} and outif=$inas{outif}");
                    $rrdUpdate->( 'filename' => "$rrdPath/$border/$filename.rrd", 'inif' => $inas{inif}, 'outif' => $inas{outif}, 'type' => '2bps' );

                    if ( !$drawGraphsOnRequest ) {

                        #draw png files while we're at it...
                        $rrdDraw->(
                            'filename'    => "$rrdPath/$border/$filename.rrd",
                            'dstfile'     => "$pictureDir/$border/$filename-daily.png",
                            'destination' => "$pictureDir/$border",
                            'title'       => "Traffic for AS$asn (on $border)",
                            'type'        => '2bps'
                        );
                    }    #if(!$drawGraphsOnRequest)
                }    #if($inas...)

                if ( $outas{inif} > $getConfig->( 'spoofThreshold', \%sources, $border ) || $outas{outif} > $getConfig->( 'spoofThreshold', \%sources, $border ) ) {
                    my $filename = "outas$asn";    # update just outbound, if it exists
                    get_logger->debug("$border: global: Updating rrd ($filename) for as $asn as outas with inif=$outas{inif} and outif=$outas{outif}");
                    $rrdUpdate->( 'filename' => "$rrdPath/$border/$filename.rrd", 'inif' => $outas{inif}, 'outif' => $outas{outif}, 'type' => '2bps' );

                    if ( !$drawGraphsOnRequest ) {

                        #draw png files while we're at it...
                        $rrdDraw->(
                            'filename'    => "$rrdPath/$border/$filename.rrd",
                            'dstfile'     => "$pictureDir/$border/$filename-daily.png",
                            'destination' => "$pictureDir/$border",
                            'title'       => "Traffic for AS$asn (on $border)",
                            'type'        => '2bps'
                        );
                    }    #if(!$drawGraphsOnRequest)
                }    #if($outas...
            }    #foreach my $asn (keys %participatingASes
        }    #if process{'as'}

        ################################
        # gather AS 'Internet' traffic #
        ################################

        #this traffic will be drawn later.

        foreach my $as ( keys %internetTraffic ) {

            #see if this border has internet-labeled interfaces

            get_logger()->info("Gathering Internet traffic for AS $as on $border");

            #for $border, look into each interface and sum up the traffic for this AS.
            my %interfaceDescriptions = $getConfig->( 'interfaces', \%sources, $border );
            foreach my $if ( keys %interfaceDescriptions ) {

                #skip this interface unless it is of type 'internet'
                my $interfacePeerType = $getConfig->( 'ifPeerType', \%sources, $border, $if );
                next if ( $interfacePeerType ne 'internet' );

                #get the interface type
                my @interfaceType = $getConfig->( 'interfaceType', \%sources, $border, $if );
                foreach my $ifType (@interfaceType) {

                    #gather the values.
                    my @output         = ();
                    my $modifiedIfType = $ifType;
                    $modifiedIfType =~ s/if/ if/;    #insert an extra space
                    @output = `$nfdump -r /data/nfsen/profiles/live/$border/nfcapd.$timeslot -n 1 -s as/bytes -o extended '$modifiedIfType $if and as $as'`;

                    foreach my $line (@output) {

                        if ( $line =~ /Summary: total flows: $bytes_string, total bytes: ($bytes_string), total packets:/ ) {

                            # record the rest of the values from the summary.

                            my $total_bytes = $1;
                            if ( $total_bytes =~ /[0-9]{1,}\.[0-9] M/ ) {    #we have bytes in M -> convert.
                                $total_bytes =~ s/M$//;                      #cut the M
                                $total_bytes = $total_bytes * 1000000;       #multiply by 1 milion
                            }
                            if ( $total_bytes =~ /[0-9]{1,}\.[0-9] G/ ) {    #we have bytes in G -> convert.
                                $total_bytes =~ s/G$//;                      #cut the G
                                $total_bytes = $total_bytes * 1000000000;    #multiply by 10^9
                            }

                            #correct by the sampling rate, if it's desired.
#                            $total_bytes *= $getConfig->( 'sampleRate', \%sources, $border ) if ( $getConfig->( 'multiplySamplingRate', \%sources, $border ) );

                            get_logger()->debug("Got $total_bytes bytes on $border, $ifType $if for AS $as");

                            #				get_logger()->debug("<>Adding $total_bytes for $ifType for as $as to INTERNET ($internetTrafficValues{$as}{$ifType}) on $border") if($as eq '21220');
                            #save it
                            $internetTrafficValues{$as}{$ifType} = 0 if ( !defined $internetTrafficValues{$as}{$ifType} );

                            $internetTrafficValues{$as}{$ifType} += $total_bytes;

                        }    #if $line=~/Summary/
                    }    #foreach my $line (@output)
                }    #foreach my $ifType
            }    #foreach my $if
        }    #foreach my $as (keys %internetTraffic)

    }    #foreach my border

    #after we have gone through all the borders, we will graph Internet Traffic for the selected ASes.

    foreach my $as ( keys %internetTrafficValues ) {

        #update the rrd and graph (if desired)
        my $filename = "as$as";
        if ( !-d $internetTrafficRRDDir || !-d $internetTrafficPictureDir ) {
            get_logger()->info("Creating $internetTrafficRRDDir and $internetTrafficPictureDir");
            mkdir( $internetTrafficRRDDir,     0777 ) or die "Unable to create $internetTrafficRRDDir. $!";
            mkdir( $internetTrafficPictureDir, 0777 ) or die "Unable to create $internetTrafficPictureDir. $!";

            chmod 0775, "$internetTrafficRRDDir", "$internetTrafficPictureDir";
        }

        my %bps;
        $bps{'inif'}  = $internetTrafficValues{$as}{'inif'} * 8 / 300;
        $bps{'outif'} = $internetTrafficValues{$as}{'outif'} * 8 / 300;

        #	get_logger()->debug("<>INTERNET traffic for as $as: $bps{'inif'}, $bps{'outif'} bps; bytes: $internetTrafficValues{$as}{'inif'}, $internetTrafficValues{$as}{'outif'}") if ($as eq '21220');
        get_logger()->debug("INTERNET TRAFFIC: AS$as has inif=$bps{'inif'} bps; outif=$bps{'outif'} bps");
        $rrdUpdate->( 'filename' => "$internetTrafficRRDDir/$filename.rrd", 'inif' => "$bps{'inif'}", 'outif' => "$bps{'outif'}", 'type' => '2bps' );
        if ( !$drawGraphsOnRequest ) {

            #draw png files while we're at it...
            $rrdDraw->( 'filename' => "$internetTrafficRRDDir/$filename.rrd", 'dstfile' => "$internetTrafficPictureDir/$filename-daily.png", 'destination' => "$internetTrafficPictureDir", 'title' => "Internet traffic for AS$as", 'type' => '2bps' );
        }    #if(!drawGraphsOnRequest)
    }

    #after we have gone through all the borders, we will graph Internet Traffic for the selected prefixes.

    foreach my $prefix ( keys %internetTrafficValuesPerPrefix ) {

        #	get_logger()->debug("<> Updating INTERNET rrd for $prefix with values $internetTrafficValuesPerPrefix{$prefix}{'inif'},$internetTrafficValuesPerPrefix{$prefix}{'outif'} bps ") if($prefix eq '89.123.0.0/16');
        #update the rrd and graph (if desired)
        my $filename = "$prefix";
        if ( !-d $internetTrafficRRDDir || !-d $internetTrafficPictureDir ) {
            get_logger()->info("Creating $internetTrafficRRDDir and $internetTrafficPictureDir");
            mkdir( $internetTrafficRRDDir,     0777 ) or die "Unable to create $internetTrafficRRDDir. $!";
            mkdir( $internetTrafficPictureDir, 0777 ) or die "Unable to create $internetTrafficPictureDir. $!";

            chmod 0775, "$internetTrafficRRDDir", "$internetTrafficPictureDir";
        }

        my %bps;
        $bps{'inif'}  = $internetTrafficValuesPerPrefix{$prefix}{'inif'};
        $bps{'outif'} = $internetTrafficValuesPerPrefix{$prefix}{'outif'};

        $filename =~ s/\//_/;

        get_logger()->debug("INTERNET TRAFFIC: Prefix $prefix has inif=$bps{'inif'} bps; outif=$bps{'outif'} bps");
        $rrdUpdate->( 'filename' => "$internetTrafficRRDDir/$filename.rrd", 'inif' => "$bps{'inif'}", 'outif' => "$bps{'outif'}", 'type' => '2bps' );
        if ( !$drawGraphsOnRequest ) {

            #draw png files while we're at it...
            $rrdDraw->(
                'filename'    => "$internetTrafficRRDDir/$filename.rrd",
                'dstfile'     => "$internetTrafficPictureDir/$filename-daily.png",
                'destination' => "$internetTrafficPictureDir",
                'title'       => "Internet traffic for prefix $prefix",
                'type'        => '2bps'
            );
        }    #if(!drawGraphsOnRequest)
    }

    ###############################
    # Draw current execution time #
    ###############################

    #draw a nice rrd (+ graph for currentExecutionTime)
    my $currentExecutionTime = time() - $startTime;

    get_logger()->info("Current execution time: $currentExecutionTime seconds.");
    $rrdUpdate->( 'filename' => "$rrdPath/executionTime.rrd", 'inif' => "$currentExecutionTime", 'type' => '1bps' );
    if ( !$drawGraphsOnRequest ) {

        #draw png files while we're at it...
        $rrdDraw->( 'filename' => "$rrdPath/executionTime.rrd", 'dstfile' => "$pictureDir/executionTime-daily.png", 'destination' => "pictureDir", 'title' => "PrefixStats execution time", 'type' => '1bps' );
    }    #if(!drawGraphsOnRequest)

}    #end of run()

sub Init {
    syslog( "info", "prefixStats: Init" );

    # Init some vars
    $nfdump     = "$NfConf::PREFIX/nfdump";
    $PROFILEDIR = "$NfConf::PROFILEDATADIR";
    my $logger = get_logger();
    $logger->level($INFO);

    my $appender = Log::Log4perl::Appender->new( "Log::Dispatch::File", filename => "/var/log/prefixStats.log", mode => "append" );
    $logger->add_appender($appender);
    my $layout = Log::Log4perl::Layout::PatternLayout->new("%d %p> %F{1}:%L %M - %m%n");
    $appender->layout($layout);

    my $version = '2.2.4';
    $logger->info("starting prefixStats version $version");

    return 1;
}

sub BEGIN {
    syslog( "info", "prefixStats BEGIN" );

    # Standard BEGIN Perl function - See Perl documentation
    # not used here
}

sub END {

    #	syslog("info", "prefixStats END");
    #	get_logger()->info("stopping prefixStats");
    # Standard END Perl function - See Perl documentation
    # not used here
}

1;
