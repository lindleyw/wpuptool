package WebApp v0.0.1 {

    use Moose;
    use Module::Pluggable search_path => [join('::',__PACKAGE__ #, 'Plugins'
					  )], require => 1,
	before_require => sub{ print "BEFORE_REQUIRE: " . join('|', @_) . "\n"; 1; };

    has 'database', is => 'ro', isa => 'Maybe[HashRef]'; # connection information

    sub backup_database {
	my $self = shift;

	return undef unless defined $self->database;
	# Hashref slice:
	my ($user, $pass, $host, $db) = @{$self->database}{'user','passwd','host','name'};
	
	$pass =~ s/"/\"/g;
	$pass =~ s/\$/\\\$/g;
	if (!$host) {
	    $host = 'localhost';
	}

	if ($user && $pass && $host && $db) {

	    # print "BACKUP DB: ($user, $pass, $host, $db)\n"; 
	    # shell hack: password sent in the blind, and not in temp
	    # file; not even 'ps axf' can see it
	    `printf '[client]\npassword=%s\n' "$pass" | 3<&0 mysqldump  --defaults-file=/dev/fd/3 $db -u $user -h $host >/tmp/\`date +$db-%Y%m%d-%H%M.sql\``;
	}
    }

    sub simplify_version {
	my $version = shift;
	$version =~ s{(\w+-\w+)-.*}{$1}; # eliminate beta minutiae after second dash
	return $version;
    }

    sub check_directory {
	my $self = shift;
	my $dire = shift;
	my $found_app;

	print "in check...\n";
	foreach my $plugin($self->plugins) {
	    print "($plugin: $dire)\n";
	    next unless $plugin->can('find_app');
	    # foreach app_locations()
	    last if defined ($found_app = $plugin->find_app($dire));
	}
	$found_app;
    }

}

1;
