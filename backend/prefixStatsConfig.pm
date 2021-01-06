#!/usr/bin/perl

package prefixStatsConfig;

#
#  developed by Adrian Popa
#

# small module that holds the function to load PrefixStats config file
# used by prefixStats.pm and the web interface
# added support to change the size of the pics on the fly

use strict;
use warnings;
use Switch;
use RRD::Simple ();
use AutoLoader 'AUTOLOAD';

require Exporter;

our @ISA = qw(Exporter);

# If you do not need this, moving things directly into @EXPORT or @EXPORT_OK
# will save memory.
our %EXPORT_TAGS = ( 'all' => [ qw(
	    getConfig rrdUpdate rrdDraw
	    ) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw(

);



#### Preloaded methods ########



#### Autoloader goes below #########
1;
__END__

# sub that parses the configuration and returns various bits of config.

sub getConfig {
    my $paramName = shift;
    my $config = shift;
    my $param1 = shift || undef;
    my $param2 = shift || undef;

    if($paramName eq 'sources'){
        my @sources = sort keys %{$config};
        return @sources;
    }
    if($paramName eq 'interfaces'){
        my %if;
        my $source = $param1;
        foreach my $ifIndex (keys %{$config->{$source}{'interfaces'}}){
            $if{$ifIndex} = $config->{$source}{'interfaces'}{$ifIndex}{'description'};
        }
        return %if;
    }
    if($paramName eq 'personalAS'){
        my $source = $param1;
        return $config->{$source}{'personalAS'};
    }
    if($paramName eq 'calculateGlobalASBasedOnInterfaceSum') {
        my $source = $param1;
        return $config->{$source}{'calculateGlobalASBasedOnInterfaceSum'};
    }
    if($paramName eq 'sourceURL') {
        my $source = $param1;
        return $config->{$source}{'sourceURL'};
    }
    if($paramName eq 'pieURL') {
        my $source = $param1;
        return $config->{$source}{'pieURL'};
    }
    if($paramName eq 'sampleRate') {
        my $source = $param1;
        return $config->{$source}{'sampleRate'};
    }
    if($paramName eq 'multiplySamplingRate') {
        my $source = $param1;
        return $config->{$source}{'multiplySamplingRate'};
    }
    if($paramName eq 'drawOnlyTop20SrcPrefix') {
        my $source = $param1;
        return $config->{$source}{'drawOnlyTop20SrcPrefix'};
    }
    if($paramName eq 'drawTopXSources') {
        my $source = $param1;
	    my $if = $param2;
	    if(! defined $if){
	        #return the global parameter
            return $config->{$source}{'drawTopXSources'};
	    }
	    else{
	        #return the interface's parameter
	        return $config->{$source}{'interfaces'}{$if}{'drawTopXSources'};
	    }
    }
    if($paramName eq 'comment') {
        my $source = $param1;
        return $config->{$source}{'comment'};
    }
    if($paramName eq 'deleteUnusedRRD') {
        my $source = $param1;
        return $config->{$source}{'deleteUnusedRRD'};
    }
    if($paramName eq 'hideInactiveASHours') {
        my $source = $param1;
        return $config->{$source}{'hideInactiveASHours'};
    }
    if($paramName eq 'srcPrefix') {
        my $source = $param1;
        return @{$config->{$source}{'srcPrefix'}};
    }
    if($paramName eq 'dstPrefix') {
        my $source = $param1;
        return @{$config->{$source}{'dstPrefix'}};
    }
    if($paramName eq 'ifASType') {
        my $source = $param1;
        my $if = $param2;
        my %hash;
        $hash{'src as'} = $config->{$source}{'interfaces'}{$if}{'src as'};
        $hash{'dst as'} = $config->{$source}{'interfaces'}{$if}{'dst as'};
        return %hash;
    }
    if($paramName eq 'ifPeerType') {
        my $source = $param1;
        my $if = $param2;
        my $type = $config->{$source}{'interfaces'}{$if}{'peerType'}||undef;
	return $type;
    }

    if($paramName eq 'interfaceType') {
        my $source = $param1;
        my $if = $param2;
        return @{$config->{$source}{'interfaces'}{$if}{'interfaceType'}};
    }
    if($paramName eq 'spoofThreshold') {
	my $source = $param1;
	return $config->{$source}{'spoofThreshold'};
    }
#    else{
#            #in case nobody matched, make sure we issue the propper warnings!
#            warn "Configuration item '$paramName' not understood!\n";
#        }

}

# sub that updates the RRD files

sub rrdUpdate{
    my (%parameters) = @_;

    my $filename = $parameters{'filename'};
    my $inif = $parameters{'inif'};
    my $outif = $parameters{'outif'};
    my $type = $parameters{'type'};

    my $rrd = RRD::Simple->new();
    if($type eq '1bps'){
        my $bps = 0;
        $bps = $inif if (defined $inif && $inif > 0);
        $bps = $outif if (defined $outif && $outif > 0);
        #this is a RRD for execution time.
	if (! -f "$filename" ) {
            #create the rrd.
            $rrd->create(
                "$filename",
                time => "GAUGE",
            );
        }
        #update the rrd (new or old)
        $rrd->update(
            "$filename",
            time => $bps,
        );
    }
    elsif($type eq '2bps'){
        #this is a RRD for prefixes, when we have incoming and outgoing flow information
        if (! -f "$filename" ) {
            #create the rrd.
            $rrd->create(
                "$filename",
                inbound_bps  => "GAUGE",
                outbound_bps => "GAUGE",
            );
        }
        #update the rrd (new or old).
	if(defined $inif && $inif > 0 && defined $outif && $outif >0){
    	    $rrd->update(
        	"$filename",
        	inbound_bps  => $inif,
		outbound_bps => $outif,
    	    );
	}
	elsif(defined $inif && $inif > 0){
    	    $rrd->update(
        	"$filename",
        	inbound_bps  => $inif,
    	    );
	}
	elsif(defined $outif && $outif > 0){
    	    $rrd->update(
        	"$filename",
        	outbound_bps => $outif,
    	    );
	}
    }
    else{
        #we only know 2 types of rrd. we should not get here.
        #die screaming
        get_logger->fatal("Unknown type of rrd requested: $type. Check your code!");
    }

    #check to see if we managed to update the file, else - print a report.
    if ( !-f "$filename" ) {
        get_logger->warn("Unable to create $filename!");
    }
}

#sub that draws the rrd files

sub rrdDraw {
    my (%parameters) = @_;

    my $filename = $parameters{'filename'};
    my $destination = $parameters{'destination'};
    my $dstfile = $parameters{'dstfile'};
    my $title = $parameters{'title'};
    my $type = $parameters{'type'};
    my $width = $parameters{'width'} || 669;
    my $height = $parameters{'height'} || 281;
    my $start = $parameters{'start'} || undef;
    my $end = $parameters{'end'} || undef;

    my $rrd = RRD::Simple->new();
    if($type eq '1bps'){
        my %rtn = $rrd->graph(
             "$filename",
             destination      => "$destination",
             title            => "$title",
             vertical_label   => "seconds",
             width            => $width,
             height           => $height,
             extended_legend  => "1",
             sources          => [qw(time)],
             source_colors    => [qw (ff6633)],
             source_drawtypes => [qw(AREA)],
             interlaced       => "",
	     timestamp	      => "rrd",
	     "start"	      => $start,
	     "end"	      => $end
        );
    }
    elsif($type eq '2bps'){
        my %rtn = $rrd->graph(
             "$filename",
             destination      => "$destination",
             title            => "$title",
             vertical_label   => "bits per second",
             width            => $width,
             height           => $height,
             extended_legend  => "1",
             sources          => [qw(inbound_bps outbound_bps)],
             source_colors    => [qw (00CF00 002894)],
             source_labels    => [ ( "Inbound", "Outbound" ) ],
             source_drawtypes => [qw(AREA LINE)],
             interlaced       => "",
	     timestamp 	      => "rrd",
	     "start"	      => $start,
	     "end"	      => $end
        );
    }
    else{
        #we only know 2 types of rrd. we should not get here.
        #die screaming
        get_logger->fatal("Unknown type of rrd requested: $type. Check your code!\n");
    }

    if ( !-f $dstfile ) {
        get_logger->warn("Unable to create $dstfile!");
    }
    else {
        my $weekly = $dstfile;
        $weekly =~s/-daily.png$/-weekly.png/;
        my $monthly =$dstfile;
        $monthly =~s/-daily.png$/-monthly.png/;
        my $annual = $dstfile;
        $annual =~s/-daily.png$/-annual.png/;
        chmod 0664, "$dstfile", "$weekly", "$monthly", "$annual";
    }
}

#1;
