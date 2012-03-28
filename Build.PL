
use strict;
use warnings;

use Module::Build 0.3601;


my %module_build_args = (
  "build_requires" => {
    "Module::Build" => "0.3601"
  },
  "configure_requires" => {
    "Module::Build" => "0.3601"
  },
  "dist_abstract" => "Test Setup::* modules",
  "dist_author" => [
    "Steven Haryanto <stevenharyanto\@gmail.com>"
  ],
  "dist_name" => "Test-Setup",
  "dist_version" => "1.01",
  "license" => "perl",
  "module_name" => "Test::Setup",
  "recommends" => {},
  "recursive_test_files" => 1,
  "requires" => {
    "Setup" => "1.",
    "perl" => "5.010000"
  },
  "script_files" => []
);


my $build = Module::Build->new(%module_build_args);

$build->create_build_script;
