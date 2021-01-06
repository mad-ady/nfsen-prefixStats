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
#my $pictureDir = "/var/www/html/statistics.bad/pics";
#my $rrdDir = "/var/www/html/statistics.bad/rrds";

#if you need to override any of these variables, do it here:
#@borders =();
	
my $time_recent = time - (6*60); #6 minutes ago

print start_html('');

if(param()){
    my $border=param('border');
    my $if=param('if');
    my $ifName=param('ifName');
    
    
#    print "border=$border<br>if=$if";
    my $hideInactiveASHours = $getConfig->('hideInactiveASHours', \%sources, $border);
    my $aDayAgo = time - ($hideInactiveASHours * 60 * 60); #$hideInactiveASHours ago
    
    my $title= "Global traffic for $border";
    $title= "Traffic for $border on interface $ifName" if ($if >0);
    print h2({-align=>'center', -style=>'font-family: Verdana;'}, "$title");
    print h3({-align=>'center', -style=>'font-family: Verdana;'}, "*".$getConfig->('comment', \%sources, $border)."*") if(defined $getConfig->('comment', \%sources, $border));
    print br;

    if($if<0){
	$if="";
    }

    print <<EOHTML;
<table
 style="width: 1200px; height: 108px; text-align: left; margin-left: auto; margin-right: auto;"
  border="0" cellpadding="2" cellspacing="2">
    <tbody>
	<tr>
	  <td style="width: 350px; text-align: center; font-family: Verdana;">Source Prefix</td>
	  <td style="width: 350px; text-align: center; font-family: Verdana;">Destination Prefix</td>
	 <td style="width: 250px; text-align: center; font-family: Verdana;">Internet AS</td>
        <td style="width: 250px; text-align: center; font-family: Verdana;">Local AS</td>
     </tr>
     <tr>
       <td style="width: 350px; font-family: Verdana;">

EOHTML

        #read the dir and display prefix links:
        my @files=<$rrdDir/$border/$if/srcpfx[0-9]*.rrd>;
        print "<blockquote>";
        foreach my $file (@files){
            #find the file's last modified time (to display differently active flows)
	    my $mtime =  (stat($file))[10];
    	    my $recentString="";
            if($time_recent < $mtime){
	        $recentString="<font color='#006633'>(new)</font>";
            }
	    else{
	    	#it's an old one. Is it older than X hours?
		if($aDayAgo < $mtime){
		    #it was updated in the last X hours
		    $recentString="<font color='#666666'>(old)</font>";
		}
		else{
		    #skip it.
		    next;
		}
            }
    
	    #parse $file
    	    my $f=$file;
	    $f=~s/^$rrdDir\/$border\/$if\///g;
	    $f=~s/\.rrd//;
    	    $f=~s/_/\//;
	    $f=~s/srcpfx//;
    	    print "<a href='element.pl?go=$file' target='right' style='color: rgb(122, 0, 0);'>$f</a> $recentString <br>\n";
            
        }
        print "</blockquote>";
	
	print <<EOHTML;       
       </td>
       <td style="width: 350px; font-family: Verdana;">
EOHTML
       
        #read the dir and display prefix links:
        @files=<$rrdDir/$border/$if/[0-9]*.rrd>;
        print "<blockquote>";
        foreach my $file (@files){
            #find the file's last modified time (to display differently active flows)
	    my $mtime =  (stat($file))[10];
    	    my $recentString="";
            if($time_recent < $mtime){
	        $recentString="<font color='#006633'>(new)</font>";
#		warn "$file is new\n";
            }
	    else{
		#it's an old one. Is it older than X hours?
		if($aDayAgo < $mtime){
		    #it was updated in the last X hours
		    $recentString="<font color='#666666'>(old)</font>";
		}
		else{
		    #skip it.
		    next;
		}
            }
    
	    #parse $file
    	    my $f=$file;
	    $f=~s/^$rrdDir\/$border\/$if\///g;
	    $f=~s/\.rrd//;
    	    $f=~s/_/\//;
    	    print "<a href='element.pl?go=$file' target='right' style='color: rgb(122, 0, 0);'>$f</a> $recentString <br>\n";
            
        }
        print "</blockquote>";
	
	print <<EOHTML;       
       </td>
       <td style="width: 250px; font-family: Verdana;">
EOHTML
	#read the dir and display Internet AS (if available)

        @files=<$rrdDir/$border/$if/outas*.rrd>;
        print "<blockquote>";
        foreach my $file (@files){
            #find the file's last modified time (to display differently active flows)
	    my $mtime =  (stat($file))[10];
    	    my $recentString="";
            if($time_recent < $mtime){
	        $recentString="<font color='#006633'>(new)</font>";
            }
	    else{
		#it's an old one. Is it older than X hours?
		if($aDayAgo < $mtime){
		    #it was updated in the last X hours
		    $recentString="<font color='#666666'>(old)</font>";
		}
		else{
		    #skip it.
		    next;
		}
    	        
            }
    
	    #parse $file
    	    my $f=$file;
	    $f=~s/^$rrdDir\/$border\/$if\///g;
	    $f=~s/\.rrd//;
    	    $f=~s/_/\//;
	    $f=~s/outas/AS /;

	    my $asn=$f;
    	    $asn=~s/AS //;
	    my $speed= '';
	    $speed = 'fast' if (defined param('resolveAS') && param('resolveAS')==0);
	    my $asName=`./getASName.pl AS$asn $speed`;
	    chomp $asName;
			    
    	    print "<a href='element.pl?go=$file' target='right' title='$asName' style='color: rgb(122, 0, 0);'>$f</a> $recentString <br>\n";
            
        }
        print "</blockquote>";


	print <<EOHTML;       
	</td>
       <td style="width: 250px; font-family: Verdana;">
EOHTML
	#read the dir and display Local AS (if available)

        @files=<$rrdDir/$border/$if/inas*.rrd>;
        print "<blockquote>";
        foreach my $file (@files){
            #find the file's last modified time (to display differently active flows)
	    my $mtime =  (stat($file))[10];
    	    my $recentString="";
            if($time_recent < $mtime){
	        $recentString="<font color='#006633'>(new)</font>";
            }
	    else{
		#it's an old one. Is it older than 24 hours?
		if($aDayAgo < $mtime){
		    #it was updated in the last 24 hours
		    $recentString="<font color='#666666'>(old)</font>";
		}
		else{
		    #skip it.
		    next;
		}
            }
    
	    #parse $file
    	    my $f=$file;
	    $f=~s/^$rrdDir\/$border\/$if\///g;
	    $f=~s/\.rrd//;
    	    $f=~s/_/\//;
	    $f=~s/inas/AS /;
	    
	    my $asn=$f;
    	    $asn=~s/AS //;
	    my $speed= '';
	    $speed = 'fast' if (defined param('resolveAS') && param('resolveAS')==0);
	    my $asName=`./getASName.pl AS$asn $speed`;
	    chomp $asName;
	    
    	    print "<a href='element.pl?go=$file' target='right' title='$asName' style='color: rgb(122, 0, 0);'>$f</a> $recentString <br>\n";
            
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