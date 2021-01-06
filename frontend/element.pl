#!/usr/bin/perl
use warnings;
use strict;
use CGI;
use CGI::Carp qw(fatalsToBrowser);
use POSIX qw(strftime);          
use Time::Local;                 


print "Content-Type: text/html\n\n";

my %FORM;
my $cgi = new CGI;
for my $key ( $cgi->param() ) {
    $FORM{$key} = $cgi->param($key);
#    print "<br>$key => $FORM{$key}\n";
}

#find if the pictures exist, if not, generate them from the rrd file.
#if the pictures are older than the rrd, update the pictures; else, show the pictures.

#load configuration

#we assume the CONFDIR is hardcoded (it's set at installation time)
my $CONFDIR  = '/data/nfsen/etc';
my $CONFFILE = 'prefixStats.conf';

#we load the configuration.
# read prefixStats.conf from CONFDIR

if ( !-f "$CONFDIR/$CONFFILE" ) {

    print "Unable to read configuration file $CONFDIR/$CONFFILE!";
    exit;
}

do "$CONFDIR/$CONFFILE" or print "Unable to execute configuration file $CONFDIR/$CONFFILE";

use lib '/data/nfsen/plugins';
use prefixStatsConfig;

my $getConfig = \&prefixStatsConfig::getConfig;
my $rrdDraw   = \&prefixStatsConfig::rrdDraw;

my %sources = %PSConfig::sources;

#we save the initial variables.

my $pictureDir = $PSConfig::pictureDir;
my $rrdDir     = $PSConfig::rrdDir;

my $internetTrafficRRDDir     = $PSConfig::internetTrafficRRDDir;
my $internetTrafficPictureDir = $PSConfig::internetTrafficPictureDir;

if ( defined $FORM{"go"} ) {
    if($FORM{"go"} eq '' && defined $FORM{searchAs}){
	#we're seaching for an AS
#	print "DBG:". $FORM{'query'};
	#exit;
	#1. Did the user type in AS 1234, or did he type in a name?
	my $asn=undef;
	my $query = $FORM{'query'};
	$query=~/^\s*(?:[aA][sS]\s*)?([0-9]{1,5})\s*$/;
	if(defined $1){
	    $asn = $1;
	}
	else{
	    #the user must have typed in a name. Translate it to a ASN
	    open ASN, "asn.txt" or die "Unable to read asn.txt. $!";
	    while(<ASN>){
		if(/$query/i){
		    $_=~/^AS([0-9]{1,5})\s+/;
		    $asn=$1;
		}
	    }
	}
	
	die "Unable to find any AS from '$query'. Try with an AS number instead." if(! defined $asn);
#	print "DBG: Using $asn<br>";	
	
	#2. We need to find at least one rrd for this AS (to save in 'go')
	foreach my $border (keys %sources){
	    my %interfaceDescriptions = $getConfig->( 'interfaces', \%sources, $border );                                                                                           
	    foreach my $if ( keys %interfaceDescriptions ) {                                                                                                                        
		if( -f "$rrdDir/$border/$if/inas$asn.rrd"){
		    $FORM{"go"}= "$rrdDir/$border/$if/inas$asn.rrd";
		    last;
		}
		if( -f "$rrdDir/$border/$if/outas$asn.rrd"){
		    $FORM{"go"}= "$rrdDir/$border/$if/outas$asn.rrd";
		    last;
		}
	    }
	}
	
	if($FORM{"go"} eq ''){
	    #couldn't find any file
	    die "Couldn't find any traffic to/from AS $asn";
	}
#	print "DBG: Using ".$FORM{"go"};
	
	
#	exit;
    }
    my $border    = '';
    my $interface = '';
    my $rrdfile   = '';
    my $pngfile   = '';

    my $rrd    = $FORM{"go"};
    my $string = $rrd;

    #get the border, from the string
    $string =~ s/$rrdDir\///;

    $string =~ /^([^\/]+)\//;
    $border = $1;

    #get the interface from the string
    $string =~ s/$border\///;
    $string =~ /^([^\/]*)\//;
    $interface = $1 || '';

    #get the rrd file from the string
    $string =~ s/$interface\///;
    $rrdfile = $string;    #must be a rrd file.

    $pngfile = $rrdfile;
    $pngfile =~ s/\.rrd/-daily.png/;

    my $rrdmtime = ( stat($rrd) )[10];
    my $png      = $pictureDir . "/" . $border . "/" . $interface . "/" . $pngfile;

    #see if a picture exists.
    my $update_png = 1;

    if ( -f $png ) {

        #get mtime.
        my $pngmtime = ( stat($png) )[10];

        #if the png is older than the rrd, update the png
        if ( $pngmtime < $rrdmtime ) {

            #update the png
            $update_png = 1;
        }
        else {
            $update_png = 0;
        }
    }

	#    my $rrd_profile = RRD::Simple->new();

        my $prefix = '';
        if ( $pngfile =~ /^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}_[0-9]{1,2})/ ) {
            $prefix = $1;
            $prefix =~ s/_/\//;
        }
        if ( $pngfile =~ /^srcpfx([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}_[0-9]{1,2})/ ) {
            $prefix = $1;
            $prefix =~ s/_/\//;
            $prefix =~ s/srcpfx/source prefix /;
        }

        if ( $pngfile =~ /^inas([0-9]+)/ ) {
            $prefix = "local AS " . $1;
        }
        if ( $pngfile =~ /^outas([0-9]+)/ ) {
            $prefix = "remote AS " . $1;
        }
        if ( $pngfile =~ /^as([0-9]+)/ && defined $FORM{'internetTraffic'} ) {
            $prefix = "AS " . $1;
        }
        if ( $pngfile =~ /executionTime/ ) {
            $prefix = "";
        }

        my $title = "Traffic for $prefix (";
        my %intDes = $getConfig->( 'interfaces', \%sources, $border ) if ( $interface ne '' );
        $title .= $intDes{$interface} . " " if ( $interface ne '' );
        $title .= "on $border)";

        $title = "Internet Traffic for $prefix" if ( defined $FORM{'internetTraffic'} );

        $title = "Execution time for prefixStats" if ( $pngfile =~ /executionTime/ );

    #update png
    if ($update_png) {

        mkdir( "$pictureDir/$border", 0777 ) if ( !-d "$pictureDir/$border" );
        mkdir( "$pictureDir/$border/$interface", 0777 ) if ( $interface ne '' && !-d "$pictureDir/$border/$interface" );

        chmod 0775, "$pictureDir", "$pictureDir/$border", "$pictureDir/$border/$interface";

        my $file = $pngfile;
        $file =~ s/-daily\.png//;

        if ( $pngfile !~ /executionTime/ ) {
            $rrdDraw->( 'filename' => $rrd, 'dstfile' => "$pictureDir/$border/$interface/$file-daily.png", 'destination' => "$pictureDir/$border/$interface", 'title' => $title, 'type' => '2bps' );
        }
        else {
            $rrdDraw->( 'filename' => $rrd, 'dstfile' => "$pictureDir/$border/$interface/$file-daily.png", 'destination' => "$pictureDir/$border/$interface", 'title' => $title, 'type' => '1bps' );
        }

    }

    #show png

    my $item = $pngfile;
    $item =~ s/-daily\.png//;
    my $file = $pngfile;

    #    print $rrdfile."<br>";
    $file =~ s/-daily\.png//;

    $item =~ s/_/\//g;
    my $pfx          = $item;       #used in More internetTrafficPrefix;
    my $pfx_filename = $pngfile;    #used in More internetTrafficPrefix;

    $item =~ s/inas/ Local AS /;
    $item =~ s/outas/ Remote AS /;
    $item =~ s/srcpfx/ Source Prefix /;
    $item =~ s/as/ AS /;
    
    #if it's an AS, let's resolve it's name...
    if($item=~/ AS /){
	$pfx =~ /([0-9]{1,5})/;
	my $asn = $1;
	if(defined $asn){
	    my $name = `./getASName.pl AS$asn fast`;
	    chomp $name;
	    $item.="($name)";
	}
    }

    my $relativePath = $png;

    #    print $relativePath;
    $relativePath =~ s/^$pictureDir/pics/;
    $relativePath =~ s/\/[^\/]{1,}$//;

    #generate the times needed for zooming.
    my $zoomEndTime        = strftime "%s", localtime( time - 300 );         #it's now - 5 minutes
    my $zoomStartTimeDay   = strftime "%s", localtime( time - 86400 );       #it's a day ago
    my $zoomStartTimeWeek  = strftime "%s", localtime( time - 604800 );      #it's a week ago
    my $zoomStartTimeMonth = strftime "%s", localtime( time - 2419200 );     #it's a month ago
    my $zoomStartTimeYear  = strftime "%s", localtime( time - 29030400 );    #it's a year ago

    my $html = "<html>
<head><title>Statistics for $item</title></head>
<body>
<h3 style='font-family: Verdana;'>Statistics for $item</h3>

<div style='text-align: center'><img src=\"$relativePath/$file-daily.png\" border=\"0\" alt=\"$file-daily\"><a href='zoom.pl?action=zoom&rrd=$rrd&graph_start=$zoomStartTimeDay&graph_end=$zoomEndTime&title=$title&filename=$pngfile'><img src='zoom.gif' border='0' alt='Zoom Graph' title='Zoom Graph' style='padding: 3px;'></a></div><br><br>
";


#############
    # More details for internet traffic
############

    if ( defined $FORM{wantDetails} && defined $FORM{internetTraffic} ) {
#	print "<br> internetTrafic";
	#override the graph just shown
	$html = "<html><head><title>Statistics for $item</title></head>
	<body>
	<h3 style='font-family: Verdana;'>Statistics for $item</h3>";
        my %internetTrafficPrefix = %PSConfig::internetTrafficPrefix;
	
	
	#compile a list of peerTypes;
	my %peerTypes;
	#find if the user selected a type of internet traffic ("internet", "customer", etc - look into peerType)
	foreach my $border (keys %sources){
             my %interfaceDescriptions = $getConfig->( 'interfaces', \%sources, $border );                                                                                           
	     foreach my $if ( keys %interfaceDescriptions ) {                                                                                                                        
		#save the type        
                my $interfacePeerType = $getConfig->( 'ifPeerType', \%sources, $border, $if );                                                                                      
                $peerTypes{$interfacePeerType} = 1;
	     }
	}
	
	#draw a nice select box with the selected peer type (if needed)

	my $peerType="";
	if(! defined $FORM{peerType}){
	    #select (randomly) one of the available types if 'internet' isn't one of them
	    
	    $peerType=(defined $peerTypes{'internet'})?"internet":((keys %peerTypes)[0]);
	}
	else{
	    $peerType=$FORM{peerType};
	}
	
	$html .= "<form method='get' name='peerSelect'>
		  <input type='hidden' name='go' value='$FORM{go}'>
		  <input type='hidden' name='internetTraffic' value='1'>
		  <input type='hidden' name='wantDetails' value='1'>
		   <h4>Select interface type: <select name='peerType' onChange='document.peerSelect.submit();'>";
	foreach my $options (sort keys %peerTypes){
	    my $selected = ($peerType eq $options)?"selected":"";
	    $html.="<option value='$options' $selected>$options</option>";
	}
	$html .= "</select></h4></form>";

        $html .= "<table>";
	
	my %drawnInterfaces;
	$pfx_filename =~s/-daily\.png/.rrd/;
	
#        if ( defined $internetTrafficPrefix{"$pfx"} ) {

            #get the router list for this prefix.
            foreach my $router ( keys %sources ) {

                #get the interfaces
		
                my %intDes = $getConfig->( 'interfaces', \%sources, $router );
                foreach my $if ( keys %intDes ) {
		    		                                                                                                                                    
		    #skip this interface unless it is of type '$peerType'                                                                                                                
		    my $interfacePeerType = $getConfig->( 'ifPeerType', \%sources, $router, $if );                                                                                      
		    next if ( $interfacePeerType ne $peerType );   
		
                    my $interface = $if;
                    $interface = '' if ( scalar(%intDes) == 1 );
		    
		    my @files = ();
		    if($pfx=~/inas|outas/){
			#add in/out as as a file too for ASes
			my $filename = $pfx_filename;
			$filename=~s/inas/outas/;
			push @files, $filename;
			$filename=~s/outas/inas/;
			push @files, $filename;
		    }
		    push @files, $pfx_filename if (scalar(@files) == 0);
#		    print "\@files: @files<br>";
		    foreach my $filename (@files){
		    
                    if ( -f "$rrdDir/$router/$interface/$filename" ) {
			my $png_filename          = $filename;
		        $png_filename =~ s/\.rrd/-daily.png/;

			$drawnInterfaces{$router}{$if}="$rrdDir/$router/$interface/$filename";
                        #we have data. Redraw the png file and add it to the html
                        my $title = "Traffic for $pfx ($intDes{$if} on $router)";

                        $rrdDraw->(
                            'filename'    => "$rrdDir/$router/$interface/$filename",
                            'dstfile'     => "$pictureDir/$router/$interface/$png_filename",
                            'destination' => "$pictureDir/$router/$interface",
                            'title'       => $title,
                            'type'        => '2bps',
                            'width'       => "550",
                            'height'      => "200",
			    'start'	  => $zoomStartTimeDay,
			    'end'	  => $zoomEndTime,
                        );

                        my $relativePathLocal = "$pictureDir/$router/$interface/$png_filename";
                        $relativePathLocal =~ s/^$pictureDir/pics/;
                        $relativePathLocal =~ s/\/[^\/]{1,}$//;
                        $html .= "<tr><td width='30%'> $intDes{$if} on $router </td><td width='70%'><img src='$relativePathLocal/$png_filename'></td></tr>";

                    }
		    }
                }
            }
#        }

	#draw the compozite graph
	my @graphHashes;
	use RRDTool::OO;
	use File::Temp qw/ tempfile /;
	
	my ( $fh, $image_file_name ) = tempfile( 'totalXXXXXX', DIR => 'temporary_pictures', UNLINK => 0, SUFFIX => '.png' );	
	close $fh;	
#	my %graphHashes;
	push @graphHashes, (image => $image_file_name);
	push @graphHashes, (vertical_label => "bits per second");
	push @graphHashes, (title => "Total $peerType traffic for $pfx");
	push @graphHashes, (width => 550);
	push @graphHashes, (height => 200);

	
	my $cdef_in="";
	my $cdef_out="";
	my $oneFile = "";
	my $index=0;
	#draw outbound_bps
	foreach my $router (keys %drawnInterfaces){
	    foreach my $if (keys %{$drawnInterfaces{$router}}){
		$oneFile = "$drawnInterfaces{$router}{$if}";
		#add this ds to the calculation for outbound
		push @graphHashes, (
		    draw => {
			file      => "$drawnInterfaces{$router}{$if}",
#			type      => (($index > 0)?'stack':'line'),
			type      => 'hidden',
			color     => '002894',
			name	  => "out_$index",
			dsname    => "outbound_bps",
			cfunc     => 'AVERAGE'		    
		    }
		);

		#treat unknown/undefined values in the rrd as zeroes, or else the total will be undefined
		$cdef_out.="out_$index,UN,0,out_$index,IF,";
		
		#add this ds to the calculation for inbound
		push @graphHashes, (
		    draw => {
			file      => "$drawnInterfaces{$router}{$if}",
#			type      => (($index > 0)?'stack':'line'),
			type      => 'hidden',
			color     => '00CF00',
			name	  => "in_$index",
			dsname    => "inbound_bps",
			cfunc     => 'AVERAGE'		    
		    }
		);		
		#treat unknown/undefined values in the rrd as zeroes, or else the total will be undefined
		$cdef_in.="in_$index,UN,0,in_$index,IF,";
		$index++;
		
	    }
	}
	
	#add the necessary addition operations to the cdef	
	for(0..$index-2){
	    $cdef_in.="+,";
	    $cdef_out.="+,";
	}
	
	#cut the last comma
	$cdef_in=~s/,$//;
	$cdef_out=~s/,$//;
	
	#calculate and graph inbound traffic
	push @graphHashes, (
	    draw => {
		type => "area",
		color => "00CF00",
		name => "in_total",
		legend => "Total inbound",
		cdef => "$cdef_in",
		file => "$oneFile", #file is not relevant, but is mandatory
	    }
	);
	#calculate and graph outbound traffic
	push @graphHashes, (
	    draw => {
		type => "line",
		color => "002894",
		name => "out_total",
		legend => "Total outbound",
		cdef => "$cdef_out",
		file => "$oneFile", #file is not relevant, but is mandatory
	    }
	);
	
#rrd debuging
#	 use Log::Log4perl qw(:easy);
#	 Log::Log4perl->easy_init({
#	         level    => $INFO, 
#	         category => 'rrdtool',
#	         layout   => '%m%n',
#		 file    => ">>/tmp/test.log",
#         }); 
	
        # Constructor     
	my $rrd = RRDTool::OO->new(file => "$oneFile");
	$rrd->graph(
	    @graphHashes	      
	);
				     
				     

	$html .= "<tr><td width='30%'> <b>Total traffic </b></td><td width='70%'><img src='$image_file_name'></td></tr>";
        $html .= "</table>";
	

    #because it can get messy, delete all the temporary pictures older than 6 minutes ago.                                                                                          
    my $time_recent = time - (6*60);
    my @files = <temporary_pictures/total*.png>;                                                                                                                                      
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

        #draw weekly, monthly, annual graphs
        $html .= "
<div style='text-align: center'><img src=\"$relativePath/$file-weekly.png\" border=\"0\" alt=\"$file-weekly\"><a href='zoom.pl?action=zoom&rrd=$rrd&graph_start=$zoomStartTimeWeek&graph_end=$zoomEndTime&title=$title&filename=$pngfile'><img src='zoom.gif' border='0' alt='Zoom Graph' title='Zoom Graph' style='padding: 3px;'></a></div><br><br>
<div style='text-align: center'><img src=\"$relativePath/$file-monthly.png\" border=\"0\" alt=\"$file-monthly\"><a href='zoom.pl?action=zoom&rrd=$rrd&graph_start=$zoomStartTimeMonth&graph_end=$zoomEndTime&title=$title&filename=$pngfile'><img src='zoom.gif' border='0' alt='Zoom Graph' title='Zoom Graph' style='padding: 3px;'></a></div><br><br>
<div style='text-align: center'><img src=\"$relativePath/$file-annual.png\" border=\"0\" alt=\"$file-annual\"><a href='zoom.pl?action=zoom&rrd=$rrd&graph_start=$zoomStartTimeYear&graph_end=$zoomEndTime&title=$title&filename=$pngfile'><img src='zoom.gif' border='0' alt='Zoom Graph' title='Zoom Graph' style='padding: 3px;'></a></div><br>
";

    }

    $html .= '</body>
</html>';
    print $html;

    exit;
}
else {
    printPage();
}

sub printPage {
    print <<EOF;
<html>
<head><title>Traffic statistics</title></head>
<body>
<h1>You can't call this page without parameters</h1>
EOF
    exit;
}    #from printPage.

my %hash   = %PSConfig::sources;
my $scalar = $PSConfig::rrdDir;
$scalar = $PSConfig::pictureDir;
%hash = %PSConfig::internetTrafficPrefix;
$scalar = $PSConfig::internetTrafficPictureDir;
$scalar = $PSConfig::internetTrafficRRDDir;