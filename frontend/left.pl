#!/usr/bin/perl
use strict;
use warnings;

use CGI::Carp qw(fatalsToBrowser);

print "Content-Type: text/html\n\n";

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

do "$CONFDIR/$CONFFILE" or print "Unable to execute configuration file $CONFDIR/$CONFFILE";

use lib '/data/nfsen/plugins';
use prefixStatsConfig;

my $getConfig = \&prefixStatsConfig::getConfig;

my %sources = %PSConfig::sources;
my %unpriviledgedUsers = %PSConfig::unpriviledgedUsers;
my %internetTraffic = %PSConfig::internetTraffic;
my $internetTrafficRRDDir = $PSConfig::internetTrafficRRDDir;
my $rrdDir = $PSConfig::rrdDir;

#we save the initial variables.

my @borders = $getConfig->('sources', \%sources);

print <<EOHTML;
<html>
<link rel="stylesheet" type="text/css" href="sdmenu/sdmenu.css" />
<script type="text/javascript" src="sdmenu/sdmenu.js">
    /***********************************************
    * Slashdot Menu script- By DimX
    * Submitted to Dynamic Drive DHTML code library: http://www.dynamicdrive.com
    * Visit Dynamic Drive at http://www.dynamicdrive.com/ for full source code
    ***********************************************/
</script>
<script type="text/javascript">
// <![CDATA[
    var myMenu;
    window.onload = function() {
        myMenu = new SDMenu("my_menu");
	myMenu.speed = 5;   
        myMenu.init();
	myMenu.collapseAll();

    };
    // ]]>
</script>
<script type="text/javascript">
function resolveAS(doc){
    var dstLink = doc.href;
    //see if the checkbox is checked
    if(document.resolveASfrm.resolveAS.checked == false){
	//we launch the url from here
	dstLink += '&resolveAS=0';
	//alert ('Going to url '+ dstLink);
	parent.right.location = dstLink;
	return false;
    }
    else{
	return true;
    }
} 
</script>
<body>

    <div style="float: left" id="my_menu" class="sdmenu">
	  
EOHTML
foreach my $border (sort @borders){
    my $borderURL = $getConfig->('sourceURL', \%sources, $border);
    my $pieURL = $getConfig->('pieURL', \%sources, $border);
    my $sampleRate = $getConfig->('sampleRate', \%sources, $border);
    my $comment = $getConfig->('comment', \%sources, $border);

    #see the size of the top we want to run. Should be the maximum number of tops from all interfaces.
    my $maxTopSrc = 0;
    my $maxTopDst = 0;
    my %interfaceDescriptions = $getConfig->('interfaces', \%sources, $border);
    foreach my $snmpIndex (keys %interfaceDescriptions){
        my %AStype = $getConfig->('ifASType', \%sources, $border, $snmpIndex);
        if(defined $AStype{'src as'}){
            $maxTopSrc = $AStype{'src as'} if ($AStype{'src as'} > $maxTopSrc);
        }
        if(defined $AStype{'dst as'}){
            $maxTopDst = $AStype{'dst as'} if ($AStype{'dst as'} > $maxTopDst);
        }
    }
																												        

    my $customPieURL = $pieURL;
    $customPieURL=~s/pie.pl/customPie.pl/;
    
    my $prefixPieURL=$pieURL;
    $prefixPieURL=~s/pie.pl/prefixPie.pl/;

    print "<div>";
    print "<span>$border</span>\n";
    print "  <a href=''>* $comment *</a>\n" if (defined $comment || $comment ne '');
    print "  <a href=''>*Sampling rate 1:".$sampleRate."*</a>" if (defined $sampleRate);
    print "  <a href='$borderURL?border=$border&if=-1&ifName=' target='right' onClick='return resolveAS(this);'>Global statistics</a>\n";

    #if we have only one interface per border, display only global statistics:
    my %intDes = $getConfig->('interfaces', \%sources, $border);
    if(scalar(keys %intDes)==1){
	#do nothing
    }
    else {
	foreach my $if (keys %intDes){
	    print "  <a href='$borderURL?border=$border&if=$if&ifName=$intDes{$if}' target='right' onClick='return resolveAS(this);'>$intDes{$if}</a>\n";
	}
    }
    print "<a href='$pieURL?border=$border&target=inbound' target='right' onClick='return resolveAS(this);'>Top AS Download</a>" if (defined $maxTopSrc && $maxTopSrc >0 && ! defined $unpriviledgedUsers{$ENV{REMOTE_USER}});    
    print "<a href='$pieURL?border=$border&target=outbound' target='right' onClick='return resolveAS(this);'>Top AS Upload</a>" if (defined $maxTopDst && $maxTopDst >0 && ! defined $unpriviledgedUsers{$ENV{REMOTE_USER}});        
    print "<a href='$customPieURL?border=$border' target='right' onClick='return resolveAS(this);'>Custom Top AS</a>" if (! defined $unpriviledgedUsers{$ENV{REMOTE_USER}});
    print "<a href='$prefixPieURL?border=$border' target='right' onClick='return resolveAS(this);'>Custom Top Prefix</a> " if (! defined $unpriviledgedUsers{$ENV{REMOTE_USER}});
    
    print "</div>\n";

}

#display 'Internet Traffic'
print "<div>";
print "<span>Internet Traffic</span>\n";
#get the directory name for internet traffic.
my $border = $internetTrafficRRDDir;
$border=~s/$PSConfig::rrdDir\///;
print "   <a href='rightInternetTraffic.pl?border=$border&if=-1&ifName=' target='right' onClick='return resolveAS(this);'>Global statistics</a>\n";
print "</div>\n";


print "</div>\n";

#display 'Execution time'
print "<div>";
print "<p align='center'><input type='button' value='Execution time' onClick='top.right.location.href=\"element.pl?go=$rrdDir/executionTime.rrd\"';></input></p>\n";
print "</div>";

#display resolveAS
print "<form name='resolveASfrm'><input type='checkbox' name='resolveAS' value='1' checked> Resolve AS Names </input></form>";
#print "$ENV{REMOTE_USER}\n";

#avoid variable  used only once: possible typo errors
my %hashvar = %PSConfig::sources;
%hashvar = %PSConfig::unpriviledgedUsers;
my $var = $PSConfig::internetTrafficRRDDir;
%hashvar =  %PSConfig::internetTraffic;