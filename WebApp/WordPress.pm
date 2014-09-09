package WebApp::WordPress v0.0.1 {

    # WordPress Handling

    use Moose;

    extends 'WebApp';
    has 'doc_root',     is => 'ro', isa => 'Maybe[Str]';
    has 'config_file',  is => 'ro', isa => 'Maybe[Str]';
    has 'version_file', is => 'ro', isa => 'Maybe[Str]';
    has 'version',      is => 'ro', isa => 'Maybe[Str]';
    has 'version_sort', is => 'ro', isa => 'Maybe[Str]';

    use constant APP_VERSION_FILE => "/wp-includes/version.php";
    use constant APP_CONFIG_FILE  => "/config.php";

    use Regexp::Common;

    sub find_version {

	my ($self, $doc_root) = @_;

	return 0 if !defined $doc_root;

	$doc_root =~ s{/\.?/?\Z}{}; # remove trailing slash or '/./'
	my $v_file = $doc_root . APP_VERSION_FILE;
	if (-e $v_file) {
	    $self->doc_root($doc_root);
	    $self->version_file ($v_file);
	    # Find stated version from .php file
	    open DOMAIN_CFG, "<$v_file";
	    while (<DOMAIN_CFG>) {
		if (/wp_version\s*=\s*[\'\"]([-0-9.a-zA-Z]+)/) {
		    $self->version($self->simplify_version($1));
		    $self->version_sort('WP ' .$self->version);
		}
		close DOMAIN_CFG;

		return 1;
	    }
	    return 0;
	}

	sub find_database {

	    my $self = shift;
	    my %db_info;
	    my %php_server_vars;
	    $php_server_vars{'DOCUMENT_ROOT'} = $self->doc_root;

	    my $v_file = $self->doc_root() . APP_CONFIG_FILE;
	    if (-e $v_file) {
		$self->config_file($v_file);

		open DOMAIN_CFG, "<$v_file";
		while (<DOMAIN_CFG>) {
		    # Replace $_SERVER['DOCUMENT_ROOT'] with actual value of docroot
		    s<\$_SERVER\s*\[\s*$RE{quoted}{-keep}\s*\]><"'".$php_server_vars{$3.$6}."'">e;
		    # Collapse string concatenations
		    s<$RE{quoted}{-keep}\s*\.\s*$RE{quoted}{-keep}><'$3$6'>g;
		    # Treat define keyword as assignment
		    s<\bdefine\s*\(\s*$RE{quoted}{-keep}\s*,><$1=>i;
		    print "$_\n";
		    if (/'(DB_\w+)'\s*,\s*'([^\']+)'/ || /define\W+(\w+)/) {
			$db_info{lc($1)} = $2;
		    }
		}
		close DOMAIN_CFG;

		if (exists $db_info{name}) {
		    $self->database(%db_info); # save connection
		}
	    }
	}

	sub app_locations {
	    # Returns a list of standard subdirectory locations in which
	    # this application might reside.
	    return ('./', './wordpress/"');
	}

	sub find_app {
	    # Looks in the given directory, and a list of standard subdirectory locations,
	    # to find any PHPBB installations. 
	    # Returns:
	    #   an array of zero or more blessed objects representing installed applications
	    print __PACKAGE__ . ': ' . join('|',@_) . "\n";
	    ();
	}

    }

};

# ----------------------------------------------------------------

    # Subversion processing -- move this to parent object
    # my $svn_path = $wp_root . ".svn";
    # # print "{$svn_path} (" . (-e $svn_path) . ")\n" ;
    # if (-e $svn_path) {
    # 	my $svn_file = svn_file($wp_root);
    # 	if (my $svn_info = $svn_file->info) {
    # 	    $domain_info_ref->{'svn_date'} = $svn_info->date;
    # 	    $domain_info_ref->{'svn_url'} = $svn_info->url;
    # 	    $domain_info_ref->{'svn_root'} = $svn_info->root;
    # 	    if ($svn_info->url =~ m{/(tags/[^/]+|\w+)\Z}) {
    # 		$domain_info_ref->{'svn_version'} = simplify_wp_version($1);
    # 		$domain_info_ref->{'version_sort'} = 'WP ' . $domain_info_ref->{'svn_version'};
    # 	    }
    # 	}
    # }



1;
