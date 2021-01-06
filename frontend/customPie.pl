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

#we save the initial variables.

use lib '/data/nfsen/plugins';
use prefixStatsConfig;

my $getConfig = \&prefixStatsConfig::getConfig;

my %sources = %PSConfig::sources;
my $rrdDir = $PSConfig::rrdDir;


#if you need to override any of these variables, do it here:
#@borders =();
	
my $time_recent = time - (6*60); # 6 minutes ago
no warnings; #disable warnings to load the color array;
my @colors=[ qw(#4dc700 #dfb700 #ff7800 #fe2e8c #803fef #098de2 #ff9999 #ff3333 #003300 #000099 #993300 #4dc700 #dfb700 #ff7800 #fe2e8c #803fef #098de2 #ff9999 #ff3333 #003300 #000099 #993300 #4dc700 #dfb700 #ff7800 #fe2e8c #803fef #098de2 #ff9999 #ff3333 #003300 #000099 #993300 #4dc700 #dfb700 #ff7800 #fe2e8c #803fef #098de2 #ff9999 #ff3333 #003300 #000099 #993300) ];
use warnings; #enabled warnings again
my %sortedHash;
my %html;

if(param()){
    my $target = param('target') || undef;
    my $border = param('border');
    my $startTime = param('startTime') || undef;
    my $endTime = param('endTime') || undef;
    my $resolve = param('resolve') || "OFF";
    my $includeOthers = param('includeOthers') || "OFF";
    my $if = param('if') || "";
    
    $if="" if($if eq '-1');
    
    
    if(! defined $startTime || !defined $endTime){
	printTimeForm($border);
	exit;
    }
    
        
    print "Content-type: text/html\n\n";
    print "<html>
    <body style='margin-left: 20px; margin-top: 20px'><table border=0><tr>";
		    	    

    #validate parameters
    
    #convert date from Y/m/d H:M to %s
    
    my ($year,$month,$day,$hour,$min)= $startTime=~/([0-9]{4})\/([0-9]{2})\/([0-9]{2}) ([0-9]{2}):([0-9]{2})/;
    
    $startTime = timelocal('00', $min, $hour, $day, ($month-1), $year);

    ($year,$month,$day,$hour,$min)= $endTime=~/([0-9]{4})\/([0-9]{2})\/([0-9]{2}) ([0-9]{2}):([0-9]{2})/;
    
    $endTime = timelocal('00', $min, $hour, $day, ($month-1), $year);
    
    if($startTime!~/^[0-9]+$/){
	print "Start Time is not valid.";	
	exit;
    }
    if($endTime!~/^[0-9]+$/){
	print "End Time is not valid.";	
	exit;
    }
    my $maxTime = 0;
    if($getConfig->('deleteUnusedRRD', \%sources, $border)){
	my $hours = $getConfig->('deleteUnusedRRD', \%sources, $border);
        $maxTime = time - ($hours * 60 * 60); # $hours ago
    }
			
    
    my $startTimeHuman = strftime "%a %b %e %H:%M:%S %Y", localtime($startTime);
    my $endTimeHuman = strftime "%a %b %e %H:%M:%S %Y", localtime($endTime);
    

    print "<h2 style='text-align: center;'>Top AS Download</h2>" if ($target eq 'inbound');
    print "<h2 style='text-align: center;'>Top AS Upload</h2>" if ($target eq 'outbound');
    print "<p style='text-align: center; font-family: Verdana; font-size=10pt'> Traffic distribution between $startTimeHuman and $endTimeHuman</p>";
    print "<table border=0><tr>";
    print "<td> <p align='center' style='font-family: Verdana;'><b>Source AS</b></p></td>";
    print "<td> <p align='center' style='font-family: Verdana;'><b>Destination AS</b></p></td></tr><tr>";

    my @directionOrder = ();
    @directionOrder = ('outas', 'inas') if($target eq 'inbound');    
    @directionOrder = ('inas', 'outas') if($target eq 'outbound');    
    foreach my $direction ( @directionOrder ) {
    
    #display also the images, before creating them
        my ( $fh, $filename ) = tempfile( 'pieXXXXXX', DIR => 'temporary_pictures', UNLINK => 0, SUFFIX => '.png' );
        $html{$direction."_img"}=$filename;
    
    
    $target=lc($target);
    #get a list of files for the specific border/as
    my %AS=();
    
#    print "time: ".time."\n";
    #read the dir and display prefix links:
#    my @files=<$rrdDir/$border/$target*.rrd>;
    my @files;
    @files=<$rrdDir/$border/$if/$direction*.rrd>;


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
		
    
        my $as=$file;
        $as=~s/$rrdDir\/$border\/$if\/$direction//;
        $as=~s/\.rrd//;
	
	$AS{$as} = {
		    'name' => '',
		    'inbound_bps_label' => '',
		    'outbound_bps_label' => '',
		    'inbound_bps' => '',
		    'outbound_bps' => 0,
                    'inbound_bps_percent' => 0,
                    'outbound_bps_percent' => 0,
                    'color'   => '',
        };
											    
	
	if($as eq '65536' && $includeOthers eq 'OFF'){
	    #we must skip this file, because we don't want to see traffic by others.
	    next;
	}
	
	#we read it using RRDs

        my ( $start, $step, $names, $data ) = RRDs::fetch( $file, 'AVERAGE', '--start' => $startTime, '--end' => $endTime, );
        if ( RRDs::error() ) {
              die( "Can't export data: " . RRDs::error() );
        }

        # get datasource id

        my $ds = "${target}_bps";
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
                        $AS{$as}{$ds}=$value;
                    }
#                        warn "Found $value bps for $ds at time $start\n" if ( defined $value );
                    last;
                }
            }

            if ( !$found ) {
                die "Can't find datasource $ds\n";
            }
        
	    
	#next, get the names of the AS-es. If there is no name, write ASN	    
	my $asName;
	if($resolve eq 'ON'){
    	    $asName=`./getASName.pl AS$as`;
	}
	else{
	    $asName=`./getASName.pl AS$as fast`;
	}
	chomp $asName;
	    
	$AS{$as}{'name'}=$asName;
	    
    }
    
    
    #we've parsed all the files. Now, compute the percentages.
    my $ds = ${target}."_bps";
    my $sum=0;
    foreach my $as (keys %AS){
	if(defined $AS{$as}{$ds}){
	    $sum+=$AS{$as}{$ds};
	}
    }

    if ($sum ==0){
	#we didn't find any ASes, or the ASes didn't have any traffic?
	$sum=1; #so that we don't get a division by 0...
    }
    #after the hash is populated, calculate the percentages.
    my $legend;

    foreach my $as (keys %AS){
	if(defined $AS{$as}{$ds.'_percent'}){
	    $AS{$as}{$ds.'_percent'}=$AS{$as}{$ds}*100/$sum;
	    $AS{$as}{$ds.'_percent'} = sprintf("%0.2f", $AS{$as}{$ds.'_percent'});
	    if($AS{$as}{$ds.'_percent'} lt 0.01){
		$AS{$as}{$ds.'_percent'}=0;
	    }
	    $AS{$as}{$ds.'_label'}="AS$as [$AS{$as}{$ds.'_percent'}\%]";
	}
    }
    
    #graph.

    # Both the arrays should same number of entries.
    my @names;
    my @values;
    my $index=0;
    foreach my $as (keys %AS){
	if($AS{$as}{$ds.'_percent'} eq '0' || $AS{$as}{$ds.'_percent'} eq ''){
	    #ignore these
#	    print "Found $as with percentage $AS{$as}{'percent'}.<br>";
	    next;
	}
	else{
	    push @names, $AS{$as}{$ds.'_label'};
	    push @values, $AS{$as}{$ds.'_percent'};
    	    $AS{$as}{'color'}=$colors[0][$index];	    
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
    my $title = "Top $target for $border ";
    $title.="($interfaceDescriptions{$if})" if ($if ne "" && $if>0);
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
    

    #my ($fh, $filename) = tempfile('pieXXXXXX', DIR => 'temporary_pictures', UNLINK => 0, SUFFIX=>'.png');  

    #print $fh $myimage->png;
    #close $fh;
    
    $filename = $html{$direction."_img"};
    open FILE, ">$filename" or die "Unable to write to $filename\n";
    print FILE $myimage->png;
    close FILE;
    
    #sort legend by percentage.

    foreach my $as(keys %AS){
	if($AS{$as}{$ds.'_percent'} ne '0' && $AS{$as}{$ds.'_percent'} ne ''){
	    $sortedHash{$as}=$AS{$as}{$ds.'_percent'};
	}
    }
    $index=1;    
    foreach my $as (sort hashValueDescendingNum (keys(%sortedHash))){
    
	#the value for bytes (which is actually bits per second) needs to be mediated to the query interval.
	my $ticks = int(($endTime - $startTime)/300) || 1;
	
    
	my $bytes =  $AS{$as}{$ds}/$ticks;
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
	
	$AS{$as}{'color'}='#000000' if (!defined $AS{$as}{'color'});
	$AS{$as}{'name'}='' if (!defined $AS{$as}{'name'});
	
	$legend .="<tr><td><p style='font-family: Verdana; size: 10pt;'>${index}.</td><td ><strong style='font-family: Verdana; font-size: 10pt;'><font color=$AS{$as}{'color'}>AS$as</strong></td><td width='30%'><p style='font-family: Verdana; font-size: 10pt;'> $AS{$as}{'name'}</p></td><td><p style='font-family: Verdana; font-size: 10pt;'>$AS{$as}{$ds.'_percent'}\%</p></td><td><p style='font-family: Verdana; font-size: 10pt;'>$bytes</p></td></tr>\n";
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

    <body style='margin-left: 20px; margin-top: 20px; font-family: Verdana;'><h4> Enter start and end time for your query and press Generate </h4>\n";	
    
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
	firstDay       :    1		     // weeks start monday	
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
	firstDay       :    1		     // weeks start monday	
    });
</script>
EOHTML
    print p, hidden('border',$border);

    print "<p>Select desired AS group ";
    print "<select name='target'><option name='inbound' value='inbound'>Top AS Download</option>
	                        <option name='outbound' value='outbound'>Top AS Upload</option>
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
    
    print checkbox('resolve','checked','ON','Resolve the ASes to names?'), br;
    print checkbox('includeOthers','checked','ON','Include \'others\' in pie chart? (represented as AS65536)'), br;
 
    print submit('Generate','Generate'), end_form, hr;
    
    print "</body></html>";
}

sub hashValueDescendingNum {
   $sortedHash{$b} <=> $sortedHash{$a};
}


my $var=$PSConfig::rrdDir;   
my %hash = %PSConfig::sources;
