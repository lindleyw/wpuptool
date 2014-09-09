package WebApp v0.0.1 {

    use Moose;
    use Module::Pluggable search_path => [join('::',__PACKAGE__ #, 'Plugins'
					  )], require => 1,
    before_require => sub{ print "BEFORE_REQUIRE: " . join('|', @_) . "\n"; 1; };

    has 'database', is => 'ro', isa => 'Maybe[HashRef]'; # connection information

    sub simplify_wp_version {
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
