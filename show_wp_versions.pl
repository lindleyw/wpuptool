#!/usr/bin/perl
use strict;

# show_wp_versions.pl
#
# Copyright (c) 2009 William Lindley <wlindley@wlindley.com>
# All rights reserved. This program is free software; you can redistribute
# it and/or modify it under the same terms as Perl itself.

my $VERSION = "1.0";

=head1 NAME

show_wp_versions.pl

=head1 SYNOPSIS

Lists the websites currently configured in the copy of Apache running
on this system. If a website is configured to run Wordpress in one of
a few standard locations, the version of Wordpress is displayed. If that
version of Wordpress was checked out of a Subversion repository, the
tagged or trunk version is displayed as well.

=head1 USAGE

$ ./show_wp_versions.pl

sorted by domain name (subdomain names have low priority in the sort)

$ ./show_wp_versions.pl -n

sorted by numeric version number

$ ./show_wp_versions.pl -n

sorted by owning UID

=cut

use Getopt::Std;
getopt("");

use App::Info::HTTPD::Apache;
use Apache::ConfigParser;
use SVN::Class;

use Data::Dumper;

my %domain_info;
my $wp_version_file = "wp-includes/version.php";

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
    $info_ref->{$domain_name}{'name_subdomain'} = $domain_subs;
    $info_ref->{$domain_name}{'port'} = $domain_port;
    $info_ref->{$domain_name}{'name_sort'} = $plain_domain . "." . $domain_subs;
}

sub find_wp_version {
    my $domain_info_ref = shift;

    my $doc_root = $domain_info_ref->{'path'};

    foreach my $wp_root ("$doc_root/", 
			"$doc_root/wordpress/"
			) {
	my $v_file = $wp_root . $wp_version_file;
	if (-e $v_file) {
	    $domain_info_ref->{'wp_version_file'} = $v_file;
	    # my $domain_uid = (stat($v_file))[4];
	    # $domain_info_ref->{'owner'} = ( getpwuid( $domain_uid ))[0];
	    open DOMAIN_CFG, "<$v_file";
	    while (<DOMAIN_CFG>) {
		if (/wp_version\s*=\s*[\'\"]([-0-9.a-zA-Z]+)/) {
		    $domain_info_ref->{'wp_version'} = $1;
		    last;
		}
	    }
	    close DOMAIN_CFG;
	    my $svn_path = $wp_root . ".svn";
	    # print "{$svn_path}\n";
	    if (-e $svn_path) {
		my $svn_file = svn_file($wp_root);
		if (my $svn_info = $svn_file->info) {
		    $domain_info_ref->{'svn_date'} = $svn_info->date;
		    $domain_info_ref->{'svn_url'} = $svn_info->url;
		    if ($svn_info->url =~ m{/(tags/[^/]+|\w+)\Z}) {
			$domain_info_ref->{'svn_version'} = $1;
		    }
		}
	    }
	    return 1;
	}
    }
    return 0;
}

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
		$domain_info{$node_value}{'owner'} = ( getpwuid( $domain_uid ))[0];

		last if find_wp_version(\%{$domain_info{$node_value}});

	#	print "---\n", Dumper($domain_info{$node_value}), "\n";

	    }
	}
    } else {
	print "Apache is not installed. :-(\n";
    }
}

get_apache_domains();

# print Dumper(%domain_info);

my @display = keys %domain_info;

if ($::opt_n) {
    @display = sort {
	$domain_info{$::a}{'wp_version'} cmp $domain_info{$::b}{'wp_version'} ||
	    $domain_info{$::a}{'name_sort'} cmp $domain_info{$::b}{'name_sort'}
    } @display;
} elsif ($::opt_u) {
    @display = sort {$domain_info{$::a}{'owner'} cmp $domain_info{$::b}{'owner'}} @display;
} else {
    @display = sort {$domain_info{$::a}{'name_sort'} cmp $domain_info{$::b}{'name_sort'}} @display;
}

print "Using $domain_info{'~httpd'}{app} version $domain_info{'~httpd'}{version}\n\n";

my $fmt_string = "%-30s %-10s %-20s %-15s\n";
printf($fmt_string, "Domain",      "Version", "Tracking Subversion","Owner");
printf($fmt_string, "-----------", "--------","-------------------","-----");

foreach my $d (@display) {
    if ($d =~ /(\.\w{2,4}(:\d+)?|\.\w{3,}\.\w{2,}(:\d+)?)\Z/) {
	printf($fmt_string, $d, $domain_info{$d}{'wp_version'},
	       $domain_info{$d}{'svn_version'},
	       $domain_info{$d}{'owner'});
    }
}

__END__
