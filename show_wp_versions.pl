#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';
use Carp;

# show_wp_versions.pl
#
# Copyright (c) 2009-2013 William Lindley <wlindley@wlindley.com>
# All rights reserved. This program is free software; you can redistribute
# it and/or modify it under the same terms as Perl itself.

my $VERSION = "1.6";

=head1 NAME

show_wp_versions.pl

=head1 SYNOPSIS

Lists the websites currently configured in the copy of Apache running
on this system. If a website is configured to run Wordpress in one of
a few standard locations, the version of Wordpress is displayed. If that
version of Wordpress was checked out of a Subversion repository, the
tagged or trunk version is displayed as well.

=head1 USAGE

$ ./show_wp_versions.pl  [domain_regexp]

  domain_regexp, if supplied, will act only on domains matching.

      Default: sort by domain name
               (subdomain names have low priority in the sort)

 -l   Long format: include template and plugin report ~~~ unfinished
 -n   Sort by numeric version number
 -t   Sort by Subversion date/time
 -e   Sort by domain expiration date
 -u   Sort by owning UID

 -a   Display all domain names, even ones we do not have read permission
 -b   Create SQL backup files in /tmp
 -U   Force database upgrades via wget

 -i   Reset (initialize) internal database of domain information  ~~~
 -f   Specify alternate domain-information database file  ~~~

=cut

use Getopt::Std;
getopt("");

use App::Info::HTTPD::Apache;
use Apache::ConfigParser;
use SVN::Class;

use Data::Dumper;

my %domain_info;

sub split_domain_parts {
    my ($domain_name, $info_ref) = @_;

    my $domain_port = 80;
    if ($domain_name =~ /:(\d)+\Z/) {
	$domain_port = $1;
    }
    my @domain_parts = split('\.', $domain_name);
    my $domain_tld = pop(@domain_parts);
    $domain_tld =~ s/:\d+\Z//; # remove port
    if (length($domain_parts[-1]) == 3 && length($domain_tld) == 2) {
	# e.g., ".com.uk"
	$domain_tld = pop (@domain_parts) . "." . $domain_tld;
    }
    my $domain_base = pop(@domain_parts);
    my $plain_domain = "${domain_base}.${domain_tld}";
    my $domain_subs = join('.',@domain_parts);

    $info_ref->{$domain_name}{'name'} = $domain_name;
    $info_ref->{$domain_name}{'name_base'} = $domain_base;
    $info_ref->{$domain_name}{'name_plain'} = $plain_domain;  # without subdomains
    $info_ref->{$domain_name}{'name_subdomain'} = $domain_subs;
    $info_ref->{$domain_name}{'port'} = $domain_port;
    $info_ref->{$domain_name}{'name_sort'} = $plain_domain . "." . $domain_subs;
}

sub backup_database {
    my ($user, $pass, $host, $db) = @_;

    $pass =~ s/"/\"/g;
    $pass =~ s/\$/\\\$/g;
    if (!$host) {
	$host = 'localhost';
    }

    if ($user && $pass && $host && $db) {

      # print "BACKUP DB: ($user, $pass, $host, $db)\n";

      # shell hack: password sent in the blind, and not in temp file; not even 'ps axf' can see it
      `printf '[client]\npassword=%s\n' "$pass" | 3<&0 mysqldump  --defaults-file=/dev/fd/3 $db -u $user -h $host >/tmp/\`date +$db-%Y%m%d-%H%M.sql\``;
    }
}

#
# PHPBB Handling
#

my $phpbb_version_file = "includes/constants.php";

sub find_phpbb_version {

# /home/someuser/public_html/includes/constants.php:define('PHPBB_VERSION', '3.0.8');

    my $domain_info_ref = shift;

    my $doc_root = $domain_info_ref->{'path'};
    return 0 if !defined $doc_root;

    foreach my $app_root ("$doc_root/", 
			"$doc_root/forum/"
			) {
	my $v_file = $app_root . $phpbb_version_file;
	$domain_info_ref->{'exists'} = 1 if (-e $app_root); # Track whether directory exists
	if (-e $v_file) {
	    $domain_info_ref->{'phpbb_version_file'} = $v_file;
	    # my $domain_uid = (stat($v_file))[4];
	    # $domain_info_ref->{'owner'} = ( getpwuid( $domain_uid ))[0];
	    
	    # Find stated Wordpress version from .php file
	    open DOMAIN_CFG, "<$v_file";
	    while (<DOMAIN_CFG>) {
		if (/\'PHPBB_VERSION\'\s*,\s*[\'\"]([-0-9.a-zA-Z]+)/) {
		    $domain_info_ref->{'phpbb_version'} = 'BB ' . simplify_wp_version($1);
		    $domain_info_ref->{'version_sort'} = $domain_info_ref->{'phpbb_version'};
		    last;
		}
	    }
	    close DOMAIN_CFG;

	    return 1;
	}
    }
    return 0;
}

sub backup_phpbb_database {

    my $domain_info_ref = shift;

    my $doc_root = $domain_info_ref->{'path'};

    foreach my $wp_root ("$doc_root/", 
			"$doc_root/forum/"
			) {
	my $v_file = $wp_root . "config.php";
	if (-e $v_file) {
	    $domain_info_ref->{'phpbb_config_file'} = $v_file;

	    open DOMAIN_CFG, "<$v_file";
	    while (<DOMAIN_CFG>) {
		if (/\$db(\w+)\s*=\s*'([^\']+)'\s*;/) {
		    my $key = lc($1); my $val = $2;
		    if ($key eq 'user' || $key eq 'name' || $key eq 'host') {
			$domain_info_ref->{"db_$key"} = $val;
		    } elsif ($key eq 'passwd') {
			$domain_info_ref->{"db_password"} = $val;
		    }
		}
	    }
	    close DOMAIN_CFG;

	    backup_database( $domain_info_ref->{'db_user'}, $domain_info_ref->{'db_password'},
			     $domain_info_ref->{'db_host'}, $domain_info_ref->{'db_name'});

	}
    }
}

#
# WordPress handling
#

my $wp_version_file = "wp-includes/version.php";

sub simplify_wp_version {
    my $version = shift;
    $version =~ s{(\w+-\w+)-.*}{$1}; # eliminate beta minutiae after second dash
    return $version;
}

sub find_wp_version {
    my $domain_info_ref = shift;

    my $doc_root = $domain_info_ref->{'path'};
    return 0 if !defined $doc_root;

    foreach my $wp_root ("$doc_root/", 
			"$doc_root/wordpress/"
			) {
	my $v_file = $wp_root . $wp_version_file;
	$domain_info_ref->{'exists'} = 1 if (-e $wp_root); # Track whether directory exists
	if (-e $v_file) {
	    $domain_info_ref->{'wp_version_file'} = $v_file;
	    # my $domain_uid = (stat($v_file))[4];
	    # $domain_info_ref->{'owner'} = ( getpwuid( $domain_uid ))[0];
	    
	    # Find stated Wordpress version from .php file
	    open DOMAIN_CFG, "<$v_file";
	    while (<DOMAIN_CFG>) {
		if (/wp_version\s*=\s*[\'\"]([-0-9.a-zA-Z]+)/) {
		    $domain_info_ref->{'wp_version'} = simplify_wp_version($1);
		    $domain_info_ref->{'version_sort'} = 'WP ' . $domain_info_ref->{'wp_version'};
		    last;
		}
	    }
	    close DOMAIN_CFG;

	    my $svn_path = $wp_root . ".svn";
	    # print "{$svn_path} (" . (-e $svn_path) . ")\n" ;
	    if (-e $svn_path) {
		my $svn_file = svn_file($wp_root);
		if (my $svn_info = $svn_file->info) {
		    $domain_info_ref->{'svn_date'} = $svn_info->date;
		    $domain_info_ref->{'svn_url'} = $svn_info->url;
		    $domain_info_ref->{'svn_root'} = $svn_info->root;
		    if ($svn_info->url =~ m{/(tags/[^/]+|\w+)\Z}) {
			$domain_info_ref->{'svn_version'} = simplify_wp_version($1);
			$domain_info_ref->{'version_sort'} = 'WP ' . $domain_info_ref->{'svn_version'};
		    }
		}
	    }
	    return 1;
	}
    }
    return 0;
}

sub find_wp_database {

    my $domain_info_ref = shift;

    my $doc_root = $domain_info_ref->{'path'};

    foreach my $wp_root ("$doc_root/", 
			"$doc_root/wordpress/"
			) {
	my $v_file = $wp_root . "wp-config.php";
	if (-e $v_file) {
	    $domain_info_ref->{'wp_config_file'} = $v_file;
	    
	    # Find stated Wordpress version from .php file
	    open DOMAIN_CFG, "<$v_file";
	    while (<DOMAIN_CFG>) {
		if (/'(DB_\w+)'\s*,\s*'([^\']+)'/) {
		    $domain_info_ref->{lc($1)} = $2;
		}
	    }
	    close DOMAIN_CFG;
	}
    }
}

sub backup_wp_database {

    my $domain_info_ref = shift;
        
    if (defined $domain_info_ref->{'db_user'} &&
        defined $domain_info_ref->{'db_password'} &&
        defined $domain_info_ref->{'db_host'} &&
        defined $domain_info_ref->{'db_name'}) {
	    backup_database( $domain_info_ref->{'db_user'}, $domain_info_ref->{'db_password'},
			     $domain_info_ref->{'db_host'}, $domain_info_ref->{'db_name'});

    }
}

use LWP::Simple;
use English;

my %wp_repository;  # Cache repository information

sub find_latest_wp {

    my $domain_info_ref = shift;
    my $repository = $domain_info_ref->{'svn_url'}->{'host'};

    if (!exists $wp_repository{$repository}) {
	# Have not already checked this repository. Note, we might put undefined in there if something goes wrong.
	my $url = 'http://' . $repository . '/tags/';
	$wp_repository{$repository}{'tags_url'} = $url;

	my $content = get $url;
	my @versions = sort ($content =~ m{<a href="([0-9a-zA-Z_][0-9a-zA-Z_.]+)/">}smg);
	$wp_repository{$repository}{'versions'} = \@versions;	
    }
    if (defined($wp_repository{$repository}{'versions'})) {
	return @{$wp_repository{$repository}{'versions'}}[-1];
    }
    return;

}


sub wordpress_needs_upgrading {

    my $domain_info_ref = shift;
    my $wp_ver = $domain_info_ref->{'svn_version'};

    # Is it a tagged version?
    if ($wp_ver !~ m{^tags/}) {
	return 0;   # no.  could be trunk or a branch.  do not upgrade.
    }

    my $latest = find_latest_wp($domain_info_ref);
    if (defined $latest) {
	$latest = "tags/$latest"; 
    }
    if ($wp_ver ge $latest) {
	return 0;   # up to date against its repository
    }

    return $latest;

}

use File::stat;
use File::chdir;
use Cwd;

sub upgrade_wordpress {

    my ($domain_info_ref, $new_version) = @_;

    # Retrieve a copy of the home page

    # Determine group and user ID for owning directory

print "EGID: " . $) . "\n";
print "EUID: " . $> . "\n";

    # Temporarily change gid, uid for svn operations
    my $version_file = $domain_info_ref->{'wp_version_file'}; # 'path'};

    my $sb = stat($version_file);
    if (!$sb) {
	warn "WRN: $version_file: $!";
	return;
    }

    # print "OK: $version_file: $!";

    my ($old_egid,$old_euid);
    $old_egid = $);
    $old_euid = $>;

    $) = $sb->gid;
    $> = $sb->uid;

    # Tell subversion to upgrade the version

    # Ensure current directory has WP installed through Subversion
    # prepare to do:   "svn switch __version__ ."
    # where __version__ is one of:
    #    $svn_base/tags/$latest_version/
    #    $svn_base/tags/trunk/
    # Then do an "svn update"

    local $CWD = $domain_info_ref->{'path'};

    my $new_svn = $domain_info_ref->{'svn_root'} . '/' . $new_version;

    print "DIRECTORY: [" . getcwd . "] executing command [$new_svn]\n";
    system('svn switch ' . $new_svn);

    $) = $old_egid;
    $> = $old_euid;

    # Retrieve a new copy of the home page

    # If new copy of home page does not include </html>, something probably went wrong


}


sub upgrade_database {

    my $domain_info_ref = shift;
    my $domain_base = $domain_info_ref->{'name_base'};

    # print Dumper($domain_info_ref);

    my $new_version = wordpress_needs_upgrading($domain_info_ref);
    if ( $new_version ) {
	upgrade_wordpress($domain_info_ref, $new_version);
    }

    my $url = "http://$domain_info_ref->{'name'}/wp-admin/upgrade.php?step=1&backto=/wp-admin/";
    my $content = get $url;

    if ($content =~ m{<h2[^>]*>(.*?)</h2}i) {
        $domain_info_ref->{'update_status'} = $1;
    }

}

sub show_wp_theme {

    my $domain_info_ref = shift;
        
    if (defined $domain_info_ref->{'db_user'} &&
        defined $domain_info_ref->{'db_password'} &&
        defined $domain_info_ref->{'db_host'} &&
        defined $domain_info_ref->{'db_name'}) {

        # Open a connection to the WP database
	#    backup_database( $domain_info_ref->{'db_user'}, $domain_info_ref->{'db_password'},
	#		     $domain_info_ref->{'db_host'}, $domain_info_ref->{'db_name'});

    }
}

sub show_wp_plugins {

    my $domain_info_ref = shift;
        
}

#
#
#

use Socket;

use Net::DNS;

use Date::Manip;
use DateTime::Format::DateManip; 

my (%mth,%mlookup);
@mth{map sprintf("%02d", $_), 1..12} = qw/jan feb mar apr may jun jul aug sep oct nov dec/;
# Lookup list for month name->abbrev conversion
@mlookup{qw/january february march april may june july august september october november december/} =
	(qw/jan feb mar apr may jun jul aug sep oct nov dec/) x 2;

# Locate 'whois' or (preferred) 'jwhois'
my ($whois) = grep -e, map "$_/jwhois", split /:/, $ENV{PATH};
($whois) = grep -e, map "$_/whois", split /:/, $ENV{PATH} unless $whois;
die "'whois'|'jwhois' not found in path.\n" unless $whois;
if ($whois =~ m#/whois$#){
	# $q || print "You really should install 'jwhois'; it gives better results.\n";
	# Turn down the noise (minimal output option - only works with 'whois')
	$whois .= " -H";
}
else {
	# Turn off caching for 'jwhois' if the debug option is on
#	$whois .= " -f" if $X;
}

sub domain_throttle_rate {
    # Returns the number of seconds to wait, between requesting the whois
    # information for domains.  If zero, the domain is not throttled; unthrottled
    # domains may be retrieved (e.g., between throttled domains) without delay.
    my $dom = shift;

    return ($dom->{'host'} =~ /\.org$/i) ? 20 : 1;

}

sub retrieve_domain_whois {
    # Process a single domain
    # Accepts as input a reference to domain hash containing
    #   'host' => domain name
    #   'server' => server to use for lookup, undef for default
    #   'cached_timestamp' => timestamp for last cached result
    #   'cached_data' => cached result data
    #   'expires' => timestamp for domain expiration
    #   '' => 
    # and a reference to configuration hash
    #   'server' => default server
    #   'cache_timeout' => number of seconds for caches to expire
    #   '' => 
    # Returns: true upon successful lookup, including cached return
    # Side effects: Modifies domain hash keys:
    #   'response' => remote server's response
    #   'error' => remote server's error; empty upon success
    #   'debug' => date processing log
    #   'registrar'
    #   'expires'
    #   'nameservers'

    # needs to strip off all but *.com, *.co.uk, etc.
    # some domains are time-limited; sort these to minimize total time.
    my ($domain, $config) = @_;
    my ($host, $server) = ($domain->{'host'}, $domain->{'server'} || $config->{'server'});

    if ($config->{'debug'}) {
	print "\b\nProcessing $host... ";
    }

    # ~~~~~~~ need to set $opt from config values ~~~~~~
    my $opt = '';

    # Execute the query, save as a single string
    open Who, "$whois $opt $domain->{'host'}|" or croak "Error executing $whois: $!\n";
    my $out = do { local $/; <Who> };
    close Who;

    $out =~ tr/\cM//d;    # Make sure it's not DOS formatted

    $domain->{'response'} = $out;

    if (!$out || $out !~ /domain/i){    # 'fgets: connection reset by peer' or other timeout
	$domain->{'error'} = "Unable to read 'whois' info for $host.";
	return 0;
    }

    if ($out =~ /no match/i){  # Domain presumably does not exist
	$domain->{'error'} = "No match for $host.";
	return 0;
    }
    if ($out =~ /No whois server is known for this kind of object/i){  # Probably wrong TLD
	$domain->{'error'} = "'whois' doesn't recognize this kind of object.";
	return 0;
    }

    # Convert multi-line 'labeled block' output to 'Label: value'
    my $debug;
    if ($out =~ /registrar:\n/i){
	$out =~ s/:\n(?!\n)/: /gsm;
	$debug .= "matched on line " . (__LINE__ - 1) . ": Multi-line 'labeled block'\n";
    }

    # Date processing; this is the heart of the program. Desired date format is '29-jun-2007'
    # 'Fri Jun 29 15:16:00 EDT 2007'
    if ($out =~ s/(date:\s*| on:\s*)[A-Z][a-z]+\s+([a-zA-Z]{3})\s+(\d+).*?(\d+)\s*$/$1$3-$2-$4/igsm){
	$debug .= "matched on line " . (__LINE__ - 1) . ": 'Fri Jun 29 15:16:00 EDT 2007'\n";
    }
    # '29-Jun-07'
    elsif ($out =~ s/(date:\s*| on:\s*)(\d{2})[\/ -](...)[\/ -](\d{2})\s*$/$1$2-$3-20$4/igsm){
	$debug .= "matched on line " . (__LINE__ - 1) . ": '29-Jun-07'\n";
    }
    # '2007-Jun-29'
    elsif ($out =~ s/[^\n]*(?:date| on|expires on\.+):\s*(\d{4})[\/-](...)[\/-](\d{2})\.?\s*$/Expiration date: $3-$2-$1/igsm){
	$debug .= "matched on line " . (__LINE__ - 1) . ": '2007-Jun-29'\n";
    }
    # '2007/06/29'
    elsif ($out =~ s/(?:renewal-|expir(?:e|es|y|ation)\s*)(?:date|on)?[ \t.:]*\s*(\d{4})(?:[\/-]|\. )(0[1-9]|1[0-2])(?:[\/-]|\. )(\d{2})(?:\.?\s*[0-9:.]*\s*\w*\s*|\s+\([-A-Z]+\)?)$/Expiration date: $3-$mth{$2}-$1/igsm){
	$debug .= "matched on line " . (__LINE__ - 1) . ": '2007/06/29'\n";
    }
    # '29-06-2007'
    elsif ($out =~ s/(?:validity:|expir(?:y|ation) date:|expire:|expires? (?:on:?|on \([dmy\/]+\):|at:))\s*(\d{2})[\/.-](0[1-9]|1[0-2])[\/.-](\d{4})\s*[0-9:.]*\s*\w*\s*$/Expiration date: $1-$mth{$2}-$3/igsm){
	$debug .= "matched on line " . (__LINE__ - 1) . ": '29-06-2007'\n";
    }
    # '[Expires on]     2007-06-29' (.jp, .ru, .ca); 'Valid Date     2016-11-02 04:21:35 EST' (yesnic.com); 'Domain Expiration Date......: 2009-01-15 GMT.' (cfolder.net)
    elsif ($out =~ s/(?:valid[- ]date|(?:renewal|expiration) date(?::|\.+:)|paid-till:|\[expires on\]|expires on ?:|expired:)\s*(\d{4})[\/.-](0[1-9]|1[0-2])[\/.-](\d{2})(?:\s*[0-9:.]*\s*\w*\s*|T[0-9:]+Z| GMT\.)$/Expiration date: $3-$mth{$2}-$1/igsm){
	$debug .= "matched on line " . (__LINE__ - 1) . ": '[Expires on]     2007-06-29' (.jp, .ru)\n";
    }
    # 'expires:     June  29[, ]+2007' (.is, PairNIC); 'Record expires on       JULY      21, 2016' (gabia.com)
    elsif ($out =~ s/(?:expires:|expires on)\s*([A-Z][a-z]+)\s+(\d{1,2})(?:\s|,)+(\d{4})\s*$/"Expiration date: " . sprintf("%02d", $2) . "-" . $mlookup{"\L$1\E"} . "-$3"/igsme){
	$debug .= "matched on line " . (__LINE__ - 1) . ": 'expires:     June  29 2007' (.is)\n";
    }
    # 'renewal: 29-June-2007'
    elsif ($out =~ s/renewal:\s*(\d{1,2})[\/ -]([A-Z][a-z]+)[\/ -](\d{4})\s*$/"Expiration date: $1-" . $mlookup{"\L$2\E"} . "-$3"/igsme){
	$debug .= "matched on line " . (__LINE__ - 1) . ": 'renewal: 29-June-2007' (.ie)\n";
    }
    # 'expire:         20080315' (.cz, .ke)
    elsif ($out =~ s/expir[ey]:\s*(\d{4})(\d{2})(\d{2})\s*$/Expiration date: $3-$mth{$2}-$1/igsm){
	$debug .= "matched on line " . (__LINE__ - 1) . ": 'expire:         20080315' (.cz, .ke)\n";
    }
    # 'domain_datebilleduntil: 2007-06-29T00:00:00+12:00' (.nz)
    elsif ($out =~ s/domain_datebilleduntil:\s*(\d{4})[-\/](\d{2})[-\/](\d{2})T[0-9:.+-]+\s*$/Expiration date: $3-$mth{$2}-$1/igsm){
	$debug .= "matched on line " . (__LINE__ - 1) . ": 'domain_datebilleduntil: 2007-06-29T00:00:00+12:00' (.nz)\n";
    }
    # '29 Jun 2007 11:58:42 UTC' (.coop)
    elsif ($out =~ s/(?:expir(?:ation|y) date|expire[sd](?: on)?)[:\] ]\s*(\d{2})[\/ -](...)[\/ -](\d{4})\s*[0-9:.]*\s*\w*\s*$/Expiration date: $1-\L$2\E-$3/igsm){
	$debug .= "matched on line " . (__LINE__ - 1) . ": '29 Jun 2007 11:58:42 UTC' (.coop)\n";
    }
    # 'Record expires on 17/8/2100' (.hm, fi)
    elsif ($out =~ s/(?:expires(?: on|:))\s*(\d{2})[\/.-]([1-9]|0[1-9]|1[0-2])[\/.-](\d{4})\s*[0-9:.]*\s*\w*\s*$/"Expiration date: $1-".$mth{sprintf "%02d", $2} . "-$3"/iegsm){
	$debug .= "matched on line " . (__LINE__ - 1) . ": 'Record expires on 17/8/2100' (.hm)\n";
    }
    # 'Expires on..............: Sat, Mar 29, 2008'
    elsif ($out =~ s/expires on\.*:\s*(?:[SMTWF][uoehra][neduit]),\s+([A-Z][a-z]+)\s+(\d{1,2}),\s+(\d{4})\s*$/"Expiration date: " . sprintf("%02d", $2) . "-\L$1-$3"/iegsm){
	$debug .= "matched on line " . (__LINE__ - 1) . ": 'Expires on..............: Sat, Mar 29, 2008'\n";
    }
    else {
	$debug = "No date regexes matched.\n";
    }

    my @nameservers; 
    my @nameservers_ip;
    # Collect the data from each query
    for (split /\n/, $out){
	s/^\s*(.*?)\s*$/$1/;   # Clip pre- and post- blanks
	tr/ \t//s;	# Squash repeated tabs and spaces
	    
	# This is where it all happens - regexes to capture registrar and expiration
	$domain->{'registrar'} ||= $1 if /(?:maintained by|registration [^:]*by|authorized agency|registrar)(?:\s*|_)(?:name|id|of record)?:\s*(.*)$/i;
	$domain->{'expires'} ||= ParseDate($1) if /(?:expires(?: on)?|expir(?:e|y|ation) date\s*|renewal(?:[- ]date)?)[:\] ]\s*(\d{2}-[a-z]{3}-\d{4})/i;
	if (m{\bName\s+server:\s+([-.a-z0-9]+)+}is) {
	    my $ns = $1;   #  convert name to IPv4 dotted quad
	    my $ns_net = inet_aton($ns);
	    if ($ns_net) {
		$ns_net = inet_ntoa($ns_net);
	    }
	    my $ns_net_printable = $ns_net ? " (${ns_net})" : '';
	    push @nameservers, "$ns$ns_net_printable";
	    push @nameservers_ip, $ns_net;
	}
    }
    
    $domain->{'nameservers'} = join(',', @nameservers);
    $domain->{'nameservers_ip'} = join(',', @nameservers_ip);

    # Assign default message if no registrar was found
    $domain->{'registrar'} ||= "[[[ No registrar found ]]]";
    if (!defined $domain->{'expires'}) {
	$domain->{'error'} .= "No expiration date found in 'whois' output."
    }
    return 1;
}

sub retrieve_domain_nameservers {

    my ($domain, $config) = @_;
    my ($host, $server) = ($domain->{'host'}, $domain->{'server'} || $config->{'server'});
    my @nameservers;
    my @nameservers_ip;

    my $res   = Net::DNS::Resolver->new;
    my $query = $res->query($host, "NS");

    if ($query) {
	foreach my $rr (grep { $_->type eq 'NS' } $query->answer) {
	    # print $rr->nsdname, "\n";
	    my $ns= $rr->nsdname;
	    my $ns_net = inet_aton($ns);
	    if ($ns_net) {
		$ns_net = inet_ntoa($ns_net);
	    }
	    my $ns_net_printable = $ns_net ? " (${ns_net})" : '';
	    $ns_net_printable = $ns_net ? " ($ns_net)" : '';
	    push @nameservers, "$ns$ns_net_printable";
	    push @nameservers_ip, $ns_net;
	}
	$domain->{'nameservers'} = join(',',@nameservers);
	$domain->{'nameservers_ip'} = join(',',@nameservers_ip);
    } else {
	# warn "query failed: ", $res->errorstring, "\n";
	$domain->{'nameservers'} = undef; # key exists but shows no nameservers defined
    }
    return 1;
}

sub sort_domains {
    # Sort domains in decreasing order of throttle value
    # Loop through list of unresolved domains.
    #   If throttle is nonzero, and required time has elapsed, look it up.
    #   If throttle is zero, look it up.
    #   ...At end of loop, if no domains were looked up this time around, wait 1 second.
}

#
#
#

sub get_apache_domains {

    my $apache = App::Info::HTTPD::Apache->new;

    if ($apache->installed) {
	$domain_info{'~httpd'}{'app'} = $apache->name;
	$domain_info{'~httpd'}{'version'} = $apache->version;
	$domain_info{'~httpd'}{'doc_root'} = $apache->doc_root;
	$domain_info{'~httpd'}{'conf_file'} = $apache->conf_file;

	# Create a new empty parser.
	my $apache_cfg = Apache::ConfigParser->new;

	# Load an Apache configuration file.
	my $parsed_config = $apache_cfg->parse_file($apache->conf_file);
	# Find all the Virtual Host entries
	#    my @vhosts = $apache_cfg->find_down_directive_names('VirtualHost');

	#    print ">>> ROOT: $apache_cfg \n";

	foreach my $site_node ($apache_cfg->find_down_directive_names('ServerName')) {
	    my $node_name = $site_node->name;
	    my $node_value = $site_node->value;

	    my @server_names = $apache_cfg->find_siblings_and_up_directive_names($site_node,'DocumentRoot');
	    foreach my $n (@server_names) {
		next if $n->{value} eq $apache->doc_root;
		# print "   $node_value  $n->{value}\n";;

		split_domain_parts($node_value, \%domain_info);
		$domain_info{$node_value}{'path'} = $n->{value};
		my $domain_uid = (stat($n->{value}))[4];
		if (defined $domain_uid) {
		    $domain_info{$node_value}{'owner'} = ( getpwuid( $domain_uid ))[0];
		}

	#	print "---\n", Dumper($domain_info{$node_value}), "\n";

	    }
	}

	# may also want to do this:
	#print "----------------ALIASES----------------\n";
        $Data::Dumper::Maxdepth = 4;
        my $domain_id = 0;
	foreach my $site_node ($apache_cfg->find_down_directive_names('ServerAlias')) {
	    # print  "- - - -\n";
	    # print  $site_node->value . "\n";
            # print  Dumper($site_node);

	    #print  $site_node->value . " an alias of: ";
	    my @server_names = $apache_cfg->find_siblings_and_up_directive_names($site_node,'ServerName');
	    foreach my $s (@server_names) {

		push @{$domain_info{$s->value}{'aliases'}}, $site_node->value;

		#print  $s->value . " ";
	    }
            #print  "\n";
	}
	#print "--------------------------------\n";
        
    } else {
	print "Apache is not installed. :-(\n";
    }
}

# Enumerate our interfaces

use IO::Interface::Simple;

# my $if1   = IO::Interface::Simple->new('eth0');
# my $if2   = IO::Interface::Simple->new_from_address('127.0.0.1');
# my $if3   = IO::Interface::Simple->new_from_index(1);

my @interfaces = IO::Interface::Simple->interfaces;

sub is_local {
    my $host = shift;
    return 0 unless defined $host;
    foreach my $if (@interfaces) {
#	print '(' . $if->address . " ?= $host) ";
	if ($if->is_running && ! $if->is_loopback && ($if->address eq $host)) {
#	    print "**** MATCH\n";
	    return 1;
	}
    }
    return 0;
}


#####################
#
# MAIN PROGRAM
#
#####################

my $domain_match = shift;   # first argument

#print "get_apache_domains()\n";
get_apache_domains();
#print Dumper(%domain_info);

my @found_domains = keys %domain_info;
my @display;
my %plain_domain_info;

# Select domains based on optional regexp.
# Find installed applications.

foreach my $d (@found_domains) {

    next if $d =~ /^~/;  # ignore our internal data
    next if (defined $domain_match && $d !~ /$domain_match/);

    if (find_wp_version(\%{$domain_info{$d}})) {
	find_wp_database(\%{$domain_info{$d}});
	if ($::opt_b) {
	    backup_wp_database(\%{$domain_info{$d}});
	}
	if ($::opt_l) {
	    show_wp_theme(\%{$domain_info{$d}});
	    # show_wp_plugins(\%{$domain_info{$d}});
	}
	if ($::opt_U) {
	    upgrade_database(\%{$domain_info{$d}});
	}
    }
    if (find_phpbb_version(\%{$domain_info{$d}})) {
	if ($::opt_b) {
	    backup_phpbb_database(\%{$domain_info{$d}});
	}
    }

    # Domain exists if we find an application, or can read doc root
    if (!defined $domain_info{$d}{'exists'}) {
	if (-e $domain_info{$d}{'path'}) {
	    $domain_info{$d}{'exists'} = 1;
	}
    }
    # Only add readable domains, unless listing all.
    next unless $::opt_a ||  $domain_info{$d}{'exists'};
    push @display, $d;

}

no warnings;   # suppress warnings about $::a and $::b
if ($::opt_n) {
    @display = sort {
	$domain_info{$::a}{'version_sort'} cmp $domain_info{$::b}{'version_sort'} ||
	    $domain_info{$::a}{'name_sort'} cmp $domain_info{$::b}{'name_sort'}
    } @display;
} elsif ($::opt_t) {
    @display = sort {$domain_info{$::a}{'svn_date'} cmp $domain_info{$::b}{'svn_date'}} @display;
} elsif ($::opt_u) {
    @display = sort {$domain_info{$::a}{'owner'} cmp $domain_info{$::b}{'owner'}} @display;
} else {
    @display = sort {$domain_info{$::a}{'name_sort'} cmp $domain_info{$::b}{'name_sort'}} @display;
}
use warnings;
no warnings 'once';

# Find the net hosts for each domain
foreach my $d (@display) {
    if ($domain_info{$d}{'name'}) {
	my $host_netaddr = inet_aton($domain_info{$d}{'name'});
	if ($host_netaddr) {
	    $domain_info{$d}{'nethost'} = inet_ntoa($host_netaddr);  # where the first A/CNAME record points
	}
    }
}

print "Using $domain_info{'~httpd'}{app} version $domain_info{'~httpd'}{version}\n\n";

#####################
#
# Process each domain
#
#####################

my $fmt_string = "%-35s %-8s %-13s %-15s %-15s\n";
print '   ' if ($::opt_u);
my $date_title = $::opt_e ? 'Expires' : 'App Date';
printf($fmt_string, "Domain",      "Notes", "Version","Owner", $date_title);
print '   ' if ($::opt_u);
printf($fmt_string, "-----------", "--------","-------","-----","----------");

my $last_uid = '';

foreach my $d (@display) {
    # Without -a flag, display only websites whose information we can extract
    next if (!$::opt_a && !$domain_info{$d}{'exists'});

    my $svn_root = $domain_info{$d}{'svn_root'} || '';
    my $svn_flag = ($svn_root =~ /automattic/) ? "[OR]" : "";
    my $app_version = '';
    my $svn_version = $domain_info{$d}{'svn_version'} || '';
    if ($svn_version =~ m{^tags/(.+)$}) {
	$app_version = "$1";
	if ($app_version ne $domain_info{$d}{'wp_version'}) {
	    $svn_flag .= '[!!]'; # mismatch!
	}
    } elsif ($domain_info{$d}{'phpbb_version'}) {
	$app_version = $domain_info{$d}{'phpbb_version'};
    } elsif ($domain_info{$d}{'wp_version'}) {
	$app_version = $domain_info{$d}{'wp_version'};
    }
    $app_version = (defined ($domain_info{$d}{'svn_version'}) ? '+':' ') . $app_version;

    if ( exists( $domain_info{$d}{'nameservers'} ) && 
	 !defined( $domain_info{$d}{'nameservers'} )) {
	$svn_flag .= '[X]';
    }

    my @datebits = split(/ /, $domain_info{$d}{'svn_date'} || '');

    # For the WHOIS, we look at $domain_info{$node_value}{'name_plain'}
    # but we need to cache those... and do appropriate delays for .org's
    my $plain_domain = $domain_info{$d}{'name_plain'};
    
	{
	    my $dom = {'host' => $plain_domain};
	    my $conf= {};
	    retrieve_domain_nameservers($dom, $conf);
	    $domain_info{$plain_domain}{'nameservers'} = $dom->{'nameservers'};
	    $domain_info{$plain_domain}{'nameservers_ip'} = $dom->{'nameservers_ip'};

	    if ($::opt_e && !defined $plain_domain_info{$plain_domain}{'expires'}) {
		# print "LOOKUP WHOIS " . $plain_domain . "\n";
		sleep (domain_throttle_rate($dom));
		retrieve_domain_whois($dom, $conf);
		$plain_domain_info{$plain_domain}{'expires'} = $dom->{'expires'};
	    }
	}

	if ($domain_info{$d}{'db_password'}) {
	    $svn_flag .= '[b]';
	}

	if (exists $domain_info{$plain_domain}{'nameservers'}) {
	    if (defined $domain_info{$plain_domain}{'nameservers_ip'}) {
		foreach my $ns (split ',',$domain_info{$plain_domain}{'nameservers_ip'}) {
		    if (!is_local($ns)) {
			$svn_flag .= '-N';  # Nameserver not here
			last;
		    }
		}
	    }
	    if (!defined $domain_info{$plain_domain}{'nameservers'}) {
		$svn_flag .= '[X]';  # Nameserver lookup returned error -- deleted?
	    }
	}	    

	if (!is_local($domain_info{$d}{'nethost'})) {
	    $svn_flag .= '-H';    # Not hosted here
	} else {
	    $svn_flag .= '+h';
	}

	if ($::opt_u) {
	    print (($domain_info{$d}{'owner'} eq $last_uid)?'   ':'-- ');
	    $last_uid = $domain_info{$d}{'owner'};
	}
	my $subdomain = $domain_info{$d}{'name_subdomain'} || '';
	printf($fmt_string, 
	       ($subdomain ? ' ':'').$d, 
	       $svn_flag,
	       $app_version,
	       $domain_info{$d}{'owner'} || '', 
	       ($::opt_e ? $plain_domain_info{$domain_info{$d}{'name_plain'}}{'expires'} : $datebits[0]) || '');
#	print $domain_info{$d}{'svn_date'}."\n";
#	print $domain_info{$d}{'svn_root'}."\n";
}
print '   ' if ($::opt_u);
printf($fmt_string, "-----------", "--------","-------","-----","----------");
print <<ENDNOTE;
   NOTES:                                     Version:			    
     [b]  = database backed up		        WP   = WordPress
     [OR] = old repository                      BB   = PHPBB
     [!!] = mismatch between SVN, wp_version    +    = under Subversion control
     [X]  = DNS lookup failed (deleted?)
     -N   = Nameserver does not point here
     -H   = 'A' record does not point here
ENDNOTE

if ($::opt_l) {
    foreach my $d (@display) {
	print "$d  ";

        if (exists $domain_info{$d}{'update_status'}) {
           print "$domain_info{$d}{'update_status'}  ";
        }


	# Display hostname if not local
	if (!is_local($domain_info{$d}{'nethost'})) {
	    my ($name, $aliases, $addrtype, $length, @addrs) = gethostbyaddr(inet_aton($domain_info{$d}{'nethost'}),AF_INET);
	    print "A=$name ";
	}

	# Display nameserver if not local
	my $plain_domain = $domain_info{$d}{'name_plain'};
	if (exists $domain_info{$plain_domain}{'nameservers'}) {
	    if (defined $domain_info{$plain_domain}{'nameservers_ip'}) {
		foreach my $ns (split ',',$domain_info{$plain_domain}{'nameservers_ip'}) {
		    if (!is_local($ns)) {
			my $name = gethostbyaddr(inet_aton($ns),AF_INET);
			print "NS=$name ";
			last;  # only show first non-local nameserver
		    }
		}
	    }
	}
	print "\n";
    }
}

__END__

