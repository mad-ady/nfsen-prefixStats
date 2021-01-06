#!/usr/bin/perl

use strict;
use warnings;

use CGI ':standard';
use GD::Graph::pie;

#use RRDTool::OO;
use RRDs;
use File::Temp qw/ tempfile /;

#load configuration

#we assume the CONFDIR is hardcoded (it's set at installation time)
my $CONFDIR  = '/data/nfsen/etc';
my $CONFFILE = 'prefixStats.conf';

#we load the configuration.
# read prefixStats.conf from CONFDIR

if ( !-f "$CONFDIR/$CONFFILE" ) {
    print "Content-type: text/html\n\n";
    print "Unable to read configuration file $CONFDIR/$CONFFILE!";
    exit;
}

do "$CONFDIR/$CONFFILE" or print "Unable to execute configuration file $CONFDIR/$CONFFILE";

#we save the initial variables.

my $rrdDir = $PSConfig::rrdDir;

#if you need to override any of these variables, do it here:
#@borders =();

my $time_recent = time - (6*60); # 6 minutes ago

no warnings; #disable warnings to load the color array;
my @colors = [
    qw(#4dc700 #dfb700 #ff7800 #fe2e8c #803fef #098de2 #ff9999 #ff3333 #003300 #000099 #993300 #4dc700 #dfb700 #ff7800 #fe2e8c #803fef #098de2 #ff9999 #ff3333 #003300 #000099 #993300 #4dc700 #dfb700 #ff7800 #fe2e8c #803fef #098de2 #ff9999 #ff3333 #003300 #000099 #993300 #4dc700 #dfb700 #ff7800 #fe2e8c #803fef #098de2 #ff9999 #ff3333 #003300 #000099 #993300)
];
use warnings; #there, we enabled warnings again;

my %sortedHash;

my %html = ();

if ( param() ) {
    my $target = param('target');
    my $border = param('border');
    print "Content-type: text/html\n\n";
    print "<html><body style='margin-left: 20px; margin-top: 20px'>";
    print "<h2 style='text-align: center;'>Top AS Download</h2>" if ($target eq 'inbound');
    print "<h2 style='text-align: center;'>Top AS Upload</h2>" if ($target eq 'outbound');
    print "<table border=0><tr>";
    print "<td> <p align='center' style='font-family: Verdana;'><b>Source AS</b></p></td>";
    print "<td> <p align='center' style='font-family: Verdana;'><b>Destination AS</b></p></td></tr><tr>";
    
    #get a list of files for the specific border/as
    #keep only the files updated within the last 6 minutes.
    my @directionOrder;
    @directionOrder = ('outas', 'inas') if ($target eq 'inbound');
    @directionOrder = ('inas', 'outas') if ($target eq 'outbound');

    foreach my $direction ( @directionOrder ) {

	#display also the images, before creating them
	my ( $fh, $filename ) = tempfile( 'pieXXXXXX', DIR => 'temporary_pictures', UNLINK => 0, SUFFIX => '.png' );
	$html{$direction."_img"}=$filename;


        my %AS = ();

        my @files;

        #read the dir and display prefix links:
        @files = <$rrdDir/$border/$direction*.rrd>;

        foreach my $file (@files) {

            #find the file's last modified time (to compute only on the final 5 minutes)
            my $mtime = ( stat($file) )[9];
            if ( $time_recent < $mtime ) {

                #new file
		#warn ("Found file $file\n");
                my $as = $file;
                $as =~ s/$rrdDir\/$border\/$direction//;
                $as =~ s/\.rrd//;

                #foreach file, read the traffic value and save it to a hash
                $AS{$as} = {
                    'name'                 => '',
                    'inbound_bps_label'    => '',
                    'outbound_bps_label'   => '',
                    'inbound_bps'          => 0,
                    'outbound_bps'         => 0,
                    'inbound_bps_percent'  => 0,
                    'outbound_bps_percent' => 0,
                    'color'                => '',
                };

                #we read it using RRDs

                my ( $start, $step, $names, $data ) = RRDs::fetch( $file, 'AVERAGE', '--start' => time() - 7 * 60, '--end' => time(), );
                if ( RRDs::error() ) {
                    die( "Can't export data: " . RRDs::error() );
                }

                # get datasource id

                my $ds = "${target}_bps";

                my $value       = undef;
                my $found       = 0;
                my $datapoint   = 0;
                my $firstTime   = $start;
                my $currentTime = $firstTime;

                for ( my $i = 0 ; $i < @$names ; $i++ ) {
                    if ( $names->[$i] eq $ds ) {
                        $found = 1;

                        #go to next value, if current value is undefined
                        while ( !defined $value && $currentTime < time() ) {

                            $value = $data->[$datapoint]->[$i] if(defined $data->[$datapoint]->[$i]);

                            #read the next data source.
                            $datapoint++;
                            $currentTime += $step;
                        }

                        #save the value (if it is defined).
                        if ( defined $value ) {
                            $AS{$as}{$ds} = $value;
			    #warn("Saved AS $as direction $ds with value $value ");
                        }

                        #                        warn "Found $value bps for $ds at time $start\n" if ( defined $value );
                        last;
                    }
                }

                if ( !$found ) {
                    die "Can't find datasource $ds\n";
                }
		
                #next, get the names of the AS-es. If there is no name, write ASN
		my $speed ='';
		$speed = 'fast' if (defined param('resolveAS') && param('resolveAS')==0);
                my $asName = `./getASName.pl AS$as $speed`;
                chomp $asName;

                $AS{$as}{'name'} = $asName;

            }
            else {

                #ignore this file - it's older than 6 minutes
            }
        }

        my $legend;

        #we've parsed all the files. Now, compute the percentages.

        my $ds = "${target}_bps";

        my $sum = 0;
        foreach my $as ( keys %AS ) {
            if ( defined $AS{$as}{$ds} ) {
                $sum += $AS{$as}{$ds};
            }
        }

        if ( $sum == 0 ) {

            #we didn't find any ASes, or the ASes didn't have any traffic?
            $sum = 1;    #so that we don't get a division by 0...
        }

        #after the hash is populated, calculate the percentages.

        foreach my $as ( keys %AS ) {
            if ( defined $AS{$as}{ $ds . "_percent" } ) {
                $AS{$as}{ $ds . '_percent' } = $AS{$as}{$ds} * 100 / $sum;
                $AS{$as}{ $ds . '_percent' } = sprintf( "%0.2f", $AS{$as}{ $ds . '_percent' } );
                if ( $AS{$as}{ $ds . '_percent' } lt 0.01 ) {
                    $AS{$as}{ $ds . '_percent' } = 0;
                }
                $AS{$as}{ $ds . '_label' } = "AS$as [$AS{$as}{$ds.'_percent'}\%]";
		#warn("Setting label for $as to AS$as [$AS{$as}{$ds.'_percent'}\%]");
            }
        }

        #graph.

        # Both the arrays should same number of entries.
        my @names;
        my @values;
        my $index = 0;
        foreach my $as ( keys %AS ) {
            if ( $AS{$as}{ $ds . '_percent' } eq '0' || $AS{$as}{ $ds . '_percent' } eq '' ) {

                #ignore these
                #    print "Found $as with percentage $AS{$as}{'percent'}.<br>";
                next;
            }
            else {
		###TEMPORARY HACK/HARDCODING###
		if($as eq '0' && $target eq 'outbound'){
		    push @names, "RTD-ROMTELECOM Autonomous System Number [".$AS{$as}{$ds.'_percent'}."]";
		    push @values, $AS{$as}{$ds.'_percent'};
		    
		}
		else{
            	    push @names,  $AS{$as}{ $ds . '_label' };
            	    push @values, $AS{$as}{ $ds . '_percent' };
		}
                $AS{$as}{'color'} = $colors[0][$index];
                $index++;
            }
        }

        if ( scalar(@names) <= 0 ) {
            print "<td><p style='font-family: Verdana;'>No active ASes found in the last 5 minutes</p></td>\n";
            next;
        }

        if ( $sum == 1 ) {
            print "<td><p style='font-family: Verdana;'>No data found in the last 5 minutes (but found " . scalar(@names) . " active sources). Are all the sources 0?</p></td>";
            next;
        }
	
	#warn("nameList: ".(@names));

        my @data = ( \@names, \@values );

#        my $mygraph = GD::Graph::pie->new( 470, 470 );
	my $mygraph = GD::Graph::pie->new( 370, 370 );
        $mygraph->set(
            title            => "Top $direction for $border",
            '3d'             => 1,
            'suppress_angle' => 2,
            'l_margin'       => 20,
            'r_margin'       => 20,
            'pie_height'     => 60,
        ) or warn $mygraph->error;

        $mygraph->set_value_font(GD::gdSmallFont);
        $mygraph->set( dclrs => @colors );

        my $myimage = $mygraph->plot( \@data ) or die $mygraph->error;

        #my ( $fh, $filename ) = tempfile( 'pieXXXXXX', DIR => 'temporary_pictures', UNLINK => 0, SUFFIX => '.png' );
	
	$filename = $html{$direction."_img"};
	open FILE, ">$filename" or die "Unable to write to $filename\n";
        print FILE $myimage->png;
        close FILE;

        #sort legend by percentage.

        foreach my $as ( keys %AS ) {
            if ( $AS{$as}{ $ds . '_percent' } ne '0' && $AS{$as}{ $ds . '_percent' } ne '' ) {
                $sortedHash{$as} = $AS{$as}{ $ds . '_percent' };
            }
        }

        $index = 1;
        foreach my $as ( sort hashValueDescendingNum ( keys(%sortedHash) ) ) {
            my $bytes = $AS{$as}{$ds};
            if ( $bytes > 1000000000 ) {
                $bytes = ( sprintf( "%0.2f", $bytes / 1000000000 ) ) . " Gb/s";
            }
            elsif ( $bytes > 1000000 ) {
                $bytes = ( sprintf( "%0.2f", $bytes / 1000000 ) ) . " Mb/s";
            }
            elsif ( $bytes > 1000 ) {
                $bytes = ( sprintf( "%0.2f", $bytes / 1000 ) ) . " Kb/s";
            }
            else {
                $bytes = sprintf( "%0.2f", $bytes ) . "b/s";
            }

	    ###HARDCODED/TEMPORARY HACK###
	    if($as eq '0' && $target eq 'outbound'){
		$legend .=
"<tr><td><p style='font-family: Verdana; font-size:10pt'>${index}.</td><td><strong style='font-family: Verdana; font-size:10pt'><font color=$AS{$as}{'color'}>AS9050</strong></td><td width='30%'><p style='font-family: Verdana; font-size:10pt'> RTD-ROMTELECOM Autonomous System Number</p></td><td><p style='font-family: Verdana; font-size:10pt'>$AS{$as}{$ds.'_percent'}\%</p></td><td><p style='font-family: Verdana; font-size:10pt'>$bytes</p></td></tr>\n";
	    }
	    else{
            $legend .=
"<tr><td><p style='font-family: Verdana; font-size:10pt'>${index}.</td><td><strong style='font-family: Verdana; font-size:10pt'><font color=$AS{$as}{'color'}>AS$as</strong></td><td width='30%'><p style='font-family: Verdana; font-size:10pt'> $AS{$as}{'name'}</p></td><td><p style='font-family: Verdana; font-size:10pt'>$AS{$as}{$ds.'_percent'}\%</p></td><td><p style='font-family: Verdana; font-size:10pt'>$bytes</p></td></tr>\n";
	    }
            $index++;
        }

        $html{$direction."_legend"}="
<td valign='top'>
<p style='font-family: Verdana;'><b> Legend:</b></p>
<table>
$legend
</table>
</td>
";
	%sortedHash=();
    }    # foreach my $direction
    
    #now, display the results.
    
    
    print "<td><img src='".$html{$directionOrder[0]."_img"}."'></td>", "<td><img src='".$html{$directionOrder[1]."_img"}."'></td></tr><tr>", $html{$directionOrder[0]."_legend"}, $html{$directionOrder[1]."_legend"} if(defined $html{$directionOrder[0]."_legend"}||defined $html{$directionOrder[1]."_legend"});
    print "</tr></table></html>";
    
    #because it can get messy, delete all the temporary pictures older than 6 minutes ago.
    my @files = <temporary_pictures/pie*.png>;
    foreach my $file (@files) {

        #find the file's last modified time
        my $mtime = ( stat($file) )[10];
        if ( $time_recent < $mtime ) {

            #new file
        }
        else {
            unlink($file);
        }
    }
    
    

}
else {
    print "Content-type: text/html\n\n";
    print "<html><font color='#ff0000'><p>This page can't be called without parameters</p></font></html>";

}

sub hashValueDescendingNum {
    $sortedHash{$b} <=> $sortedHash{$a};
}

my $var = $PSConfig::rrdDir;
