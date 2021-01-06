#!/usr/bin/perl

use strict;
use warnings;

use CGI ':standard';
use GD::Graph::pie;
#use RRDTool::OO;
use RRDs;
use File::Temp qw/ tempfile /;
use POSIX qw(strftime);
use Time::Local; 

#load configuration

#we assume the CONFDIR is hardcoded (it's set at installation time)
my $CONFDIR = '/data/nfsen/etc';
my $CONFFILE = 'prefixStats.conf';

#we load the configuration.
# read prefixStats.conf from CONFDIR

if (! -f "$CONFDIR/$CONFFILE"){
    print "Content-type: text/html\n\n";
    print "Unable to read configuration file $CONFDIR/$CONFFILE!";
    exit;
}
	
do "$CONFDIR/$CONFFILE" or print "Unable to execute configuration file $CONFDIR/$CONFFILE";

use lib '/data/nfsen/plugins';
use prefixStatsConfig;

my $getConfig = \&prefixStatsConfig::getConfig;

my %sources = %PSConfig::sources;

#we save the initial variables.

my $rrdDir = $PSConfig::rrdDir;

#if you need to override any of these variables, do it here:
#@borders =();
	
my $time_recent = time - (6*60); # 6 minutes ago

my $maxTime=0;

no warnings; #avoid error messages while loading this array
my @colors=[ qw(#4dc700 #dfb700 #ff7800 #fe2e8c #803fef #098de2 #ff9999 #ff3333 #003300 #000099 #993300 #4dc700 #dfb700 #ff7800 #fe2e8c #803fef #098de2 #ff9999 #ff3333 #003300 #000099 #993300 #4dc700 #dfb700 #ff7800 #fe2e8c #803fef #098de2 #ff9999 #ff3333 #003300 #000099 #993300 #4dc700 #dfb700 #ff7800 #fe2e8c #803fef #098de2 #ff9999 #ff3333 #003300 #000099 #993300) ];
use warnings;

my %sortedHash;

if(param()){
    my $target = param('target') || undef;
    my $border = param('border');
    my $startTime = param('startTime') || undef;
    my $endTime = param('endTime') || undef;
    my $resolve = param('resolve') || "OFF";
    my $includeOthers = param('includeOthers') || "OFF";
    my $if = param('if') || "";
    $if="" if ($if eq '-1');
        
    if(! defined $startTime || !defined $endTime || !defined $target){
	printTimeForm($border);
	exit;
    }
    
    print "Content-type: text/html\n\n";
    print "<html><body style='margin-left: 20px; margin-top: 20px'><table border=0><tr>";
    print "<td> <p align='center' style='font-family: Verdana;'><b>Inbound Traffic</b></p></td>";
    print "<td> <p align='center' style='font-family: Verdana;'><b>Outbound Traffic</b></p></td></tr><tr>";
	
	
    #validate parameters
    #convert date from Y/m/d H:M to %s                                                                                                                       
                                                                                                                                                                 
    my ($year,$month,$day,$hour,$min)= $startTime=~/([0-9]{4})\/([0-9]{2})\/([0-9]{2}) ([0-9]{2}):([0-9]{2})/;                                               
	                                                                                                                                                             
    $startTime = timelocal('00', $min, $hour, $day, ($month-1), $year);                                                                                      
                                                                                                                                                             
    ($year,$month,$day,$hour,$min)= $endTime=~/([0-9]{4})\/([0-9]{2})\/([0-9]{2}) ([0-9]{2}):([0-9]{2})/;                                                    
		                                                                                                                                                                 
    $endTime = timelocal('00', $min, $hour, $day, ($month-1), $year);  
        
    if($startTime!~/^[0-9]+$/){
	print "<p style='font-family: Verdana;'>Start Time is not valid.</p>";	
	exit;
    }
    if($endTime!~/^[0-9]+$/){
	print "<p style='font-family: Verdana;'>End Time is not valid.</p>";	
	exit;
    }
    
    my $startTimeHuman = strftime "%a %b %e %H:%M:%S %Y", localtime($startTime);
    my $endTimeHuman = strftime "%a %b %e %H:%M:%S %Y", localtime($endTime);
    
    
    if( $getConfig->('deleteUnusedRRD', \%sources, $border) ){
	my $hours =  $getConfig->('deleteUnusedRRD', \%sources, $border);
	$maxTime = time - ($hours * 60 * 60); #$hours ago
    }
        
    #get a list of files for the specific border/as
    my %PREFIX=();
    
#    print "time: ".time."\n";
    #read the dir and display prefix links:
    my @files;
    @files=<$rrdDir/$border/$if/srcpfx[0123456789]*_32.rrd> if($target eq 'srcIP');
    @files=<$rrdDir/$border/$if/srcpfx[0123456789]*.rrd> if($target eq 'srcPrefix');
    @files=<$rrdDir/$border/$if/srcpfx[0123456789]*.rrd> if($target eq 'srcPrefixHost');    
    @files=<$rrdDir/$border/$if/[0123456789]*_32.rrd> if($target eq 'dstIP');
    @files=<$rrdDir/$border/$if/[0123456789]*_*.rrd> if($target eq 'dstPrefix');
    @files=<$rrdDir/$border/$if/[0123456789]*_*.rrd> if($target eq 'dstPrefixHost');

    if($target eq 'srcPrefix' || $target eq 'dstPrefix'){
	my @tempFiles=();
	foreach my $file (@files){
	    if($file=~/$rrdDir\/$border\/$if\/(?:srcpfx)*[0-9].*_32.rrd/){
		#ignore unwanted elements
	    }
	    else{
		push @tempFiles, $file;
	    }
	}
	@files = @tempFiles;
    }


    foreach my $file (@files){
        my $mtime =  (stat($file))[9];
	if($mtime < $startTime){
	    #this file is old, skip it.
	    #see if is older than the maximum allowed time; if it is, delete it.
	    if($mtime < $maxTime){
		unlink $file or warn ("Can't delete $file: $!");
	    }
	    
	    next;
	}
		
    
        my $prefix=$file;
        $prefix=~s/$rrdDir\/$border\/$if\///;
	$prefix=~s/srcpfx//;
	$prefix=~s/_/\//;
        $prefix=~s/\.rrd//;
	
	$PREFIX{$prefix} = {
	    'name' => '',
	    'inbound_bps_label' => '',
	    'outbound_bps_label' => '',
	    'inbound_bps' => '',
	    'outbound_bps' => 0,
	    'inbound_bps_percent' => 0,
	    'outbound_bps_percent' => 0,
	    'color'   => '',
	};
	
	
	if( $target eq 'srcIP' && $prefix eq '0.0.0.0/0'){
	    next;
	}
	if( $target eq 'srcIP' && $prefix eq '0.0.0.0/32' && $includeOthers eq 'OFF'){
	    next;
	}
	if( $target eq 'srcPrefix' && $prefix eq '0.0.0.0/32'){
	    next;
	}
	if( $target eq 'srcPrefix' && $prefix eq '0.0.0.0/0' && $includeOthers eq 'OFF'){
	    next;
	}
	if( $target eq 'srcPrefixHost' && $prefix eq '0.0.0.0/32'){
	    next;
	}
	if( $target eq 'srcPrefixHost' && $prefix eq '0.0.0.0/0' && $includeOthers eq 'OFF'){
	    next;
	}
	if( $target eq 'dstIP' && $prefix eq '0.0.0.0/0'){
	    next;
	}
	if( $target eq 'dstIP' && $prefix eq '0.0.0.0/32' && $includeOthers eq 'OFF'){
	    next;
	}
	if( $target eq 'dstPrefix' && $prefix eq '0.0.0.0/32'){
	    next;
	}
	if( $target eq 'dstPrefix' && $prefix eq '0.0.0.0/0' && $includeOthers eq 'OFF'){
	    next;
	}
	if( $target eq 'dstPrefixHost' && $prefix eq '0.0.0.0/32'){
	    next;
	}
	if( $target eq 'dstPrefixHost' && $prefix eq '0.0.0.0/0' && $includeOthers eq 'OFF'){
	    next;
	}
	

	#we read it using RRDs

        my ( $start, $step, $names, $data ) = RRDs::fetch( $file, 'AVERAGE', '--start' => $startTime, '--end' => $endTime, );
        if ( RRDs::error() ) {
              die( "Can't export data: " . RRDs::error() );
        }

        # get datasource id

        foreach my $ds ( 'inbound_bps', 'outbound_bps' ) {

            my $value = 0;
            my $found = 0;
            my $datapoint = 0;
            my $firstTime = $start;
            my $currentTime = $firstTime;

            for ( my $i = 0 ; $i < @$names ; $i++ ) {
                if ( $names->[$i] eq $ds ) {
                    $found = 1;

                    #go to next value, if current value is undefined
                    while( $currentTime < $endTime ){

                        $value += $data->[$datapoint]->[$i] if(defined $data->[$datapoint]->[$i]);

                        #read the next data source.
                        $datapoint++;
                        $currentTime+=$step;
                    }
                        #save the value (if it is defined).
                    if ( defined $value ) {
                        $PREFIX{$prefix}{$ds}=$value;
                    }
#                        warn "Found $value bps for $ds at time $start\n" if ( defined $value );
                    last;
                }
            }

            if ( !$found ) {
                die "Can't find datasource $ds\n";
            }
        }
		    
	#next, get the names of the AS-es. If there is no name, write ASN	    
	my $prefixName;
	if($resolve eq 'ON'){
	    #resolve by DNS
    	    $prefixName=`./getDNSName.pl $prefix`;
	}
	else{
	    $prefixName="";
	}
	chomp $prefixName;
	    
	$PREFIX{$prefix}{'name'}=$prefixName;
	    
    }
    
    
    #we've parsed all the files. Now, compute the percentages.
    foreach my $ds ('inbound_bps', 'outbound_bps'){
    my $sum=0;
    foreach my $prefix (keys %PREFIX){
	if(defined $PREFIX{$prefix}{$ds}){
	    $sum+=$PREFIX{$prefix}{$ds};
	}
    }

    if ($sum ==0){
	#we didn't find any ASes, or the ASes didn't have any traffic?
	$sum=1; #so that we don't get a division by 0...
    }
    #after the hash is populated, calculate the percentages.
    my $legend;

    foreach my $prefix (keys %PREFIX){
	if(defined $PREFIX{$prefix}{$ds.'_percent'}){
	    $PREFIX{$prefix}{$ds.'_percent'}=$PREFIX{$prefix}{$ds}*100/$sum;
	    $PREFIX{$prefix}{$ds.'_percent'} = sprintf("%0.2f", $PREFIX{$prefix}{$ds.'_percent'});
	    if($PREFIX{$prefix}{$ds.'_percent'} lt 0.01){
		$PREFIX{$prefix}{$ds.'_percent'}=0;
	    }
	    $PREFIX{$prefix}{$ds.'_label'}="$prefix [$PREFIX{$prefix}{$ds.'_percent'}\%]";
	}
    }
    
    #graph.

    # Both the arrays should same number of entries.
    my @names;
    my @values;
    my $index=0;
    foreach my $prefix (keys %PREFIX){
	if($PREFIX{$prefix}{$ds.'_percent'} eq '0' || $PREFIX{$prefix}{$ds.'_percent'} eq ''){
	    #ignore these
	    next;
	}
	else{
	    push @names, $PREFIX{$prefix}{$ds.'_label'};
	    push @values, $PREFIX{$prefix}{$ds.'_percent'};
    	    $PREFIX{$prefix}{'color'}=$colors[0][$index];	    
	    $index++;
	}
    }

    if(scalar(@names) <= 0){
	print "<td><p style='font-family: Verdana; size: 10pt;'>No active ASes found in the specified time</p></td>\n";
        next;
    }
    
    if($sum == 1){
	print "<td><p style='font-family: Verdana; size: 10pt;'>No data found in the specified time (but found " . scalar(@names) . " active sources). Are all the sources 0?</p></td>";
	next;
    }
    
    
    
    my @data = (\@names,
	        \@values);

    my %interfaceDescriptions = $getConfig->('interfaces', \%sources, $border);
    my $title = "Top $target for $border";
    $title.=" ($interfaceDescriptions{$if})" if ($if ne "" && $if > 0);
#    my $mygraph = GD::Graph::pie->new(470, 470);
    my $mygraph = GD::Graph::pie->new(370, 370);
    $mygraph->set(
        title       => $title,
        '3d'          => 1,
	'suppress_angle' => 2,
	'l_margin'    => 20,
	'r_margin'    => 20,
	'pie_height'  => 60,
        ) or warn $mygraph->error;
		    
    $mygraph->set_value_font(GD::gdSmallFont);
    $mygraph->set(dclrs => @colors);
    
    my $myimage = $mygraph->plot(\@data) or die $mygraph->error;
    

    my ($fh, $filename) = tempfile('pieXXXXXX', DIR => 'temporary_pictures', UNLINK => 0, SUFFIX=>'.png');  

    print $fh $myimage->png;
    close $fh;
    
    #sort legend by percentage.

    foreach my $prefix(keys %PREFIX){
	if($PREFIX{$prefix}{$ds.'_percent'} ne '0' && $PREFIX{$prefix}{$ds.'_percent'} ne ''){
	    $sortedHash{$prefix}=$PREFIX{$prefix}{$ds.'_percent'};
	}
    }
    $index=1;    
    foreach my $prefix (sort hashValueDescendingNum (keys(%sortedHash))){

	#the value for bytes (which is actually bits per second) needs to be mediated to the query interval.
        my $ticks = int(($endTime - $startTime)/300) || 1;
		
        my $bytes =  $PREFIX{$prefix}{$ds}/$ticks;
        if($bytes > 1000000000){
            $bytes = ( sprintf( "%0.2f", $bytes/1000000000 )). " Gb/s";
        }
        elsif ($bytes > 1000000){
            $bytes = ( sprintf( "%0.2f", $bytes/1000000 )). " Mb/s";
        }
        elsif ($bytes > 1000){
            $bytes = ( sprintf( "%0.2f", $bytes/1000 )). " Kb/s";
        }
        else{
            $bytes = sprintf( "%0.2f", $bytes ). "b/s";
        }
	$PREFIX{$prefix}{'name'}='' if (!defined $PREFIX{$prefix}{'name'});
	$PREFIX{$prefix}{'color'}='#000000' if(!defined $PREFIX{$prefix}{'color'});
        $legend .="<tr><td><p style='font-family: Verdana; size: 10pt;'>${index}.</td><td ><strong style='font-family: Verdana; font-size: 10pt;'><font color=$PREFIX{$prefix}{'color'}>$prefix</strong></td><td width='30%'><p style='font-family: Verdana; font-size: 10pt;'> $PREFIX{$prefix}{'name'}</p></td><td><p style='font-family: Verdana; font-size: 10pt;'>$PREFIX{$prefix}{$ds.'_percent'}\%</p></td><td><p style='font-family: Verdana; font-size: 10pt;'>$bytes</p></td></tr>\n";
	$index++;
    }
    
    
    
    print <<EOHTML;
    
<td>
<p align='center'><img src='$filename'></p>
<p style='font-family: Verdana; font-size=10pt'> Traffic distribution between $startTimeHuman and $endTimeHuman</p>
<p style='font-family: Verdana;'><b> Legend:</b></p>
<table>
$legend
</table>
</td>

EOHTML
    } #foreach my $ds.

    #because it can get messy, delete all the temporary pictures older than 6 minutes ago.
    @files = <temporary_pictures/pie*.png>;
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
    print "</tr></table></html>";
    
}
else{
    print "Content-type: text/html\n\n";
    print "<html><font color='#ff0000'><p style='font-family: Verdana;'>This page can't be called without parameters</p></font></html>";

}

sub printTimeForm {
    print "Content-type: text/html\n\n";
    my $border=shift;
    
    print "<html>
    <head>                                                                                                                                                   
    <!-- calendar stylesheet -->                                                                                                                             
    <link rel=\"stylesheet\" type=\"text/css\" media=\"all\" href=\"calendar/calendar-win2k-cold-1.css\" title=\"win2k-cold-1\" />                           
                                                                                                                                                                 
    <!-- main calendar program -->                                                                                                                           
    <script type=\"text/javascript\" src=\"calendar/calendar.js\"></script>                                                                                  
		                                                                                                                                                                 
    <!-- language for the calendar -->                                                                                                                       
    <script type=\"text/javascript\" src=\"calendar/lang/calendar-en.js\"></script>                                                                          
		                                                                                                                                                                 
    <!-- the following script defines the Calendar.setup helper function, which makes                                                                        
       adding a calendar a matter of 1 or 2 lines of code. -->                                                                                               
   <script type=\"text/javascript\" src=\"calendar/calendar-setup.js\"></script>                                                                            
   </head>     
    
    <body style='margin-left: 20px; margin-top: 20px; font-family: Verdana;'><h4 style='font-family: Verdana;'> Enter start and end time for your query and press Generate </h4>\n";	
    my $startTime = strftime "%Y/%m/%d %H:%M", localtime(time - 21600); #set it 6 hours back by default                                                      
                                                                                                                                                             
    my $endTime = strftime "%Y/%m/%d %H:%M", localtime(time);                                                                                                
                                                                                                                                                             
    print start_form, "Start time: ",textfield(-name => 'startTime', -default => "$startTime", -id=>'startTimeID');                                          
    print <<EOHTML;                                                                                                                                          
    <img src="calendar/img.gif" id="startTimeButtonID"                                                                                                       
     style="cursor: pointer; border: 1px solid red;"                                                                                                         
     title="Date selector"                                                                                                                                   
     onmouseover="this.style.background='red';"                                                                                                              
     onmouseout="this.style.background=''" />                                                                                                                
<script type="text/javascript">                                                                                                                              
    Calendar.setup({                                                                                                                                         
        inputField     :    "startTimeID",      // id of the input field                                                                                     
        ifFormat       :    "%Y/%m/%d %H:%M",       // format of the input field                                                                             
        showsTime      :    true,            // will display a time selector                                                                                 
        button         :    "startTimeButtonID",   // trigger for the calendar (button ID)                                                                   
        singleClick    :    true,           // double-click mode                                                                                             
        step           :    1,                // show all years in drop-down boxes (instead of every other year as default)                                  
        firstDay       :    1                // weeks start monday                                                                                           
    });                                                                                                                                                      
</script>                                                                                                                                                    
                                                                                             
                                                                                                                                                             
EOHTML
    print  p,"End time: ", textfield(-id => 'endTimeID', -name => 'endTime', -default=> "$endTime");                                                         
    print <<EOHTML;                                                                                                                                          
    <img src="calendar/img.gif" id="endTimeButtonID"                                                                                                         
     style="cursor: pointer; border: 1px solid red;"                                                                                                         
     title="Date selector"                                                                                                                                   
     onmouseover="this.style.background='red';"                                                                                                              
     onmouseout="this.style.background=''" />                                                                                                                
<script type="text/javascript">                                                                                                                              
    Calendar.setup({                                                                                                                                         
        inputField     :    "endTimeID",      // id of the input field                                                                                       
        ifFormat       :    "%Y/%m/%d %H:%M",       // format of the input field                                                                             
        showsTime      :    true,            // will display a time selector                                                                                 
        button         :    "endTimeButtonID",   // trigger for the calendar (button ID)                                                                     
        singleClick    :    true,           // double-click mode                                                                                             
        step           :    1,                // show all years in drop-down boxes (instead of every other year as default)                                  
        firstDay       :    1                // weeks start monday                                                                                           
    });                                                                                                                                                      
</script>                                                                                                                                                    
EOHTML

    print p, hidden('border',$border);

    print "<p>Select desired prefix group ";
    print "<select name='target'><option name='srcIP' value='srcIP'>Source IP (/32)</option>
				<option name='srcPrefix' value='srcPrefix'>Source Prefix (/x)</option>
				<option name='srcPrefixHost' value='srcPrefixHost'>Source Prefix + Host (approx) (/x + /32)</option>
				<option name='dstIP' value='dstIP'>Destination IP (/32)</option>
				<option name='dstPrefix' value='dstPrefix'>Destination Prefix (/x)</option>
				<option name='dstPrefixHost' value='dstPrefixHost'>Destination Prefix + Host (approx) (/x + /32)</option>				
	   </select></p>";    
    
    my %interfaceDescriptions = $getConfig->('interfaces', \%sources, $border);
     
    if(scalar keys (%interfaceDescriptions) > 1){
	 
        print "<p>Select interface to process ";
        print "<select name='if'>";
	print "<option value='-1' selected>Global</option>";
	foreach my $index (keys %interfaceDescriptions){
	     print "<option value='$index'>$interfaceDescriptions{$index}</option>";
	}
	print "</select></p>";
    }
									     
    print checkbox('resolve','checked','ON','Resolve the prefixes by DNS?'), br;
    print checkbox('includeOthers','checked','ON','Include \'others\' in pie chart? (represented as prefix 0.0.0.0/0 or 0.0.0.0/32)'), br;

    print submit, end_form, hr;
    print "</body></html>";
}

sub hashValueDescendingNum {
   $sortedHash{$b} <=> $sortedHash{$a};
}


my $var=$PSConfig::rrdDir;   
my %hash=%PSConfig::sources;
