package WebApp::PHPBB v0.0.1 {

#
# PHPBB Handling
#
    use Moose;

    extends 'WebApp';
    has 'doc_root',     is => 'ro', isa => 'Maybe[Str]';
    has 'config_file',  is => 'ro', isa => 'Maybe[Str]';
    has 'version_file', is => 'ro', isa => 'Maybe[Str]';
    has 'version',      is => 'ro', isa => 'Maybe[Str]';
    has 'version_sort', is => 'ro', isa => 'Maybe[Str]';

    use constant APP_VERSION_FILE => "/includes/constants.php";
    use constant APP_CONFIG_FILE  => "/config.php";

    sub find_version {

	# /home/someuser/public_html/includes/constants.php:define('PHPBB_VERSION', '3.0.8');
	
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
		if (/\'PHPBB_VERSION\'\s*,\s*[\'\"]([-0-9.a-zA-Z]+)/) {
		    $self->version('BB ' . $self->simplify_version($1));
		    $self->version_sort($self->version);
		    last;
		}
	    }
	    close DOMAIN_CFG;

	    return 1;
	}
	return 0;
    }

    sub find_database {

	my $self = shift;
	my %db_info;

	my $v_file = $self->doc_root() . APP_CONFIG_FILE;
	if (-e $v_file) {
	    $self->config_file($v_file);

	    open DOMAIN_CFG, "<$v_file";
	    while (<DOMAIN_CFG>) {
		if (/\$db(\w+)\s*=\s*'([^\']+)'\s*;/) {
		    my $key = lc($1); my $val = $2;
		    if ($key eq 'user' || $key eq 'name' || $key eq 'host') {
			$db_info{$key} = $val;
		    } elsif ($key eq 'passwd') {
			$db_info{'password'} = $val;
		    }
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
	return ('./', './forum/', './phpbb/');
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




1;
