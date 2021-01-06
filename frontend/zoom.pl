#!/usr/bin/perl
use warnings;
use strict;
use CGI;
use CGI::Carp qw(fatalsToBrowser);
use File::Temp qw/ tempfile /;   
use POSIX qw(strftime);          
use Time::Local;                 

print "Content-Type: text/html\nCache-Control: no-store, no-cache, must-revalidate, post-check=0, pre-check=0\nPragma: no-cache\nExpires: Mon, 26 Jul 1997 05:00:00 GMT\n\n";

my %FORM;
my $cgi = new CGI;

#we use get parameters for this one...
for my $key ( $cgi->url_param() ) {
    $FORM{$key} = $cgi->url_param($key);
#    print "$key => $FORM{$key}<br>";
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

if ( defined $FORM{"rrd"} ) {

    my $rrd    = $FORM{"rrd"};
    my $graph_start = $FORM{"graph_start"};
    my $graph_end = $FORM{"graph_end"};
    my $title = $FORM{"title"};
    my $pngFile = $FORM{"filename"};
    
    die "Wrong rrd file - bad path: $rrd" if($rrd!~/$rrdDir/);

    #first of all, do some cleanup - delete the files we need to create - just to make sure
    #this can create a bug, where two instances zoom into the same graph at the same time
    unlink "temporary_pictures/$pngFile" if (-f "temporary_pictures/$pngFile");  

    if ( $pngFile !~ /executionTime/ ) {
        $rrdDraw->( 'filename' => $rrd, 'dstfile' => "temporary_pictures/$pngFile", 'destination' => "temporary_pictures", 'title' => "$title (zoomed)", 'start' => $graph_start, 'end' => $graph_end, 'type' => '2bps' );
    }
    else {
	$rrdDraw->( 'filename' => $rrd, 'dstfile' => "temporary_pictures/$pngFile", 'destination' => "temporary_pictures", 'title' => "$title (zoomed)", 'start' => $graph_start, 'end' => $graph_end, 'type' => '1bps' );
    }

    print "<html><head><META HTTP-EQUIV=\"CACHE-CONTROL\" CONTENT=\"NO-CACHE\">
    <META HTTP-EQUIV=\"EXPIRES\" CONTENT=\"01 Jan 1970 00:00:00 GMT\">
    <META HTTP-EQUIV=\"PRAGMA\" CONTENT=\"NO-CACHE\">";
    open JS, "zoom.js" or die "Unable to read zoom.js";

    while(<JS>){
	print;
    }

    print "</head><body><script>window.onload = initBonsai;</script>";
    print "
<!-- The zoom portion of the code is stolen mercilessly from cacti (and bonsai) -->
<div id='zoomBox' style='position:absolute; overflow:none; left:0px; top:0px; width:0px; height:0px; visibility:visible; background:red; filter:alpha(opacity=50); -moz-opacity:0.5; -khtml-opacity:0.5; opacity:0.5'></div>
<div id='zoomSensitiveZone' style='position:absolute; overflow:none; left:0px; top:0px; width:0px; height:0px; visibility:visible; cursor:crosshair; background:blue; filter:alpha(opacity=0); -moz-opacity:0; -khtml-opacity:0; opacity:0' oncontextmenu='return false'></div>
<STYLE MEDIA=\"print\">
    /*Turn off the zoomBox*/
    div#zoomBox, div#zoomSensitiveZone {display: none}
    /*This keeps IE from cutting things off*/
    #why {position: static; width: auto}
</STYLE>
";

    #show png
    print "<img id='zoomGraphImage' src='temporary_pictures/$pngFile' border='0' alt='$title'>";
    
    #before exiting, we'll delete all files older than 6 minutes
    #because it can get messy, delete all the temporary pictures older than 6 minutes ago.                                                                   
    my $time_recent = time - (6*60); # 6 minutes ago 
    my @files = <temporary_pictures/*.png>;                                                                                                               
    foreach my $file(@files){                                                                                                                                
        #find the file's last modified time                                                                                                                  
        my $mtime =  (stat($file))[10];                                                                                                                      
        if($time_recent < $mtime){                                                                                                                           
            #new file                                                                                                                                        
        }                                                                                                                                                    
        else{                                                                                                                                                
            unlink($file);                                                                                                                                   
        }                                                                                                                                                    
    }

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
$scalar = $PSConfig::internetTrafficPictureDir;
$scalar = $PSConfig::internetTrafficRRDDir;