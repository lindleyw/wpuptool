package WebApp v0.0.1 {

    use Module::Pluggable search_path => [join('::',__PACKAGE__,'Plugins')], require => 1,
    before_require => sub{ print "BEFORE_REQUIRE: " . join('|', @_) . "\n"; 1; };

    sub check_directory {
	my $self = shift;
	my $dire = shift;
	my $found_app;

	print "in check...\n";
	foreach my $plugin($self->plugins) {
	    print "($plugin: $dire)\n";
	    next unless $plugin->can('find_version');
	    last if defined ($found_app = $plugin->find_version($dire));
	}
	$found_app;
    }

}

1;
