package WebApp::Plugins::PHPBB v0.0.1 {

#
# PHPBB Handling
#

    my $phpbb_version_file = "includes/constants.php";

sub find_version {
    # Looks in the given directory, and a list of standard subdirectory locations,
    # to find any PHPBB installations. 
    # Returns:
    #   undef, or a blessed object (…?)
    print __PACKAGE__ . ': ' . join('|',@_) . "\n";
    undef;
}


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

}




1;
