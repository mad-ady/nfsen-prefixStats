#!/usr/bin/perl
use strict;
use warnings;
use CGI::Carp qw(fatalsToBrowser);
use CGI qw/:standard/;

print header;

#load configuration

#we assume the CONFDIR is hardcoded (it's set at installation time)
my $CONFDIR = '/data/nfsen/etc';
my $CONFFILE = 'prefixStats.conf';

#we load the configuration.
# read prefixStats.conf from CONFDIR

if (! -f "$CONFDIR/$CONFFILE"){

    print "Unable to read configuration file $CONFDIR/$CONFFILE!";
    exit;
}
	
do "$CONFDIR/$CONFFILE" or warn "Unable to execute configuration file $CONFDIR/$CONFFILE";

use lib '/data/nfsen/plugins';
use prefixStatsConfig;

my $getConfig = \&prefixStatsConfig::getConfig;

my %sources = %PSConfig::sources;

#we save the initial variables.

my $pictureDir = $PSConfig::pictureDir;
my $rrdDir = $PSConfig::rrdDir;

my $internetTrafficRRDDir = $PSConfig::internetTrafficRRDDir;
my $internetTrafficPictureDir = $PSConfig::internetTrafficPictureDir;

#if you need to override any of these variables, do it here:
#@borders =();
	
my $time_recent = time - (6*60); 

print start_html('');

if(param()){
    my $border=param('border');
        
    my $title= "Global Internet Traffic";

    print h2({-align=>'center', -style=>'font-family: Verdana;'}, "$title");
    print br;

    print <<EOHTML;
<table
 style="width: 900px; height: 108px; text-align: left; margin-left: auto; margin-right: auto;"
  border="0" cellpadding="2" cellspacing="2">
    <tbody>
	<tr>
	  <td style="width: 350px; text-align: center; font-family: Verdana;">Destination Prefix</td>
          <td style="width: 550px; text-align: center; font-family: Verdana;">AS</td>
     </tr>
     <tr>
       <td style="width: 350px; font-family: Verdana;">

EOHTML
       
        #read the dir and display prefix links:
        my @files=<$internetTrafficRRDDir/[0123456789]*_*.rrd>;
        print "<blockquote>";
        foreach my $file (@files){
            #find the file's last modified time (to display differently active flows)
	    my $mtime =  (stat($file))[10];
    	    my $recentString="";
            if($time_recent < $mtime){
	        $recentString="<font color='#006633'>(new)</font>";
		#warn "$file is new\n";
            }
	    else{
		#it's an old one
		$recentString="<font color='#666666'>(old)</font>";
	    }
	    
	    #parse $file
    	    my $f=$file;
	    $f=~s/^$internetTrafficRRDDir\///g;
	    $f=~s/\.rrd//;
    	    $f=~s/_/\//;
    	    print "<a href='element.pl?go=$file&internetTraffic=1' target='right' style='color: rgb(122, 0, 0);'>$f</a> [<a href='element.pl?go=$file&internetTraffic=1&wantDetails=1' target='right' style='color: rgb(122,0,0);'>More</a>] $recentString <br>\n";
            
        }
        print "</blockquote>";
	
	print <<EOHTML;       
       </td>
       <td style="width: 550px; font-family: Verdana;">
EOHTML

	#draw the select box that will let you search for an AS by name or number
	print "<h4><form method='get' action='element.pl'>Detailed traffic for AS (number or part of name):
	<input type='hidden' name='go' value=''>
	<input type='hidden' name='internetTraffic' value='1'>
	<input type='hidden' name='wantDetails' value='1'>
	<input type='text' name='query'><input type='submit' name='searchAs' value='Search'></form></h4>";

	#read the dir and display Destination AS (if available)
    

        @files=<$internetTrafficRRDDir/as*.rrd>;
        print "<blockquote>";
        foreach my $file (@files){
            #find the file's last modified time (to display differently active flows)
	    my $mtime =  (stat($file))[10];
    	    my $recentString="";
            if($time_recent < $mtime){
	        $recentString="<font color='#006633'>(new)</font>";
            }
	    else{
		#it's an old one.
		$recentString="<font color='#666666'>(old)</font>";
	    }
	
	    #parse $file
    	    my $f=$file;
	    $f=~s/^$internetTrafficRRDDir\///g;
	    $f=~s/\.rrd//;
    	    $f=~s/_/\//;
	    $f=~s/as/AS /;
	    
	    my $asn=$f;
    	    $asn=~s/AS //;
	    my $speed='';
	    $speed='fast' if (defined param('resolveAS') && param('resolveAS') == 0);
	    my $asName=`./getASName.pl AS$asn $speed`;
	    chomp $asName;
	    
    	    print "<a href='element.pl?go=$file&internetTraffic=1' target='right' title='$asName' style='color: rgb(122, 0, 0);'>$f</a> [$asName] $recentString <br>\n";
            
        }
        print "</blockquote>";


	print <<EOHTML;       
       </td>
   </tr>
</table>

EOHTML


}
else{
    print h3({-align=>'center'},'Select a router or an interface');
}


my $var=$PSConfig::rrdDir;
$var=$PSConfig::pictureDir; 
my %hash = %PSConfig::sources;
$var = $PSConfig::internetTrafficRRDDir;
$var = $PSConfig::internetTrafficPictureDir;