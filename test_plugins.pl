#!/usr/env/perl

use strict;
use warnings;


use WebApp;

my $this_dir_obj = WebApp->check_directory('foo');

print defined $this_dir_obj ? "FOUND" : "NOT FOUND";



