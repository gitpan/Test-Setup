package Test::Setup;

use 5.010;
use strict;
use warnings;

use File::chdir;
use Perinci::Access::InProcess 0.29;
use Perinci::Tx::Manager 0.29;
use Scalar::Util qw(blessed);
use Test::More 0.96;
use UUID::Random;

our $VERSION = '1.02'; # VERSION

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(test_setup);

sub test_setup {
    my %tsargs = @_;

    my $tmpdir = $tsargs{tmpdir} or die "BUG: please supply tmpdir";
    state $tm;
    my $pa = Perinci::Access::InProcess->new(
        use_tx=>1,
        custom_tx_manager => sub {
            my $self = shift;
            $tm //= Perinci::Tx::Manager->new(
                data_dir => "$tmpdir/.tx", pa => $self);
            die $tm unless blessed($tm);
            $tm;
        });

    my $name  = $tsargs{name};
    my $func  = $tsargs{function};
    if (!ref($func)) { $func = &$func }
    my $fargs = $tsargs{args};
    for (qw/-dry_run -undo_action -undo_data/) {
        exists($fargs->{$_}) and die "BUG: args should not have $_";
    }
    my $chks  = $tsargs{check_setup};
    my $chku  = $tsargs{check_unsetup};

    subtest $name => sub {
        my ($res, $undo_data, $redo_data, $undo_data2);
        my $exit;

        my $tx_id = UUID::Random::generate();
        $res = $pa->request(begin_tx => "/", {tx_id=>$tx_id});
        unless (is($res->[0], 200, "begin tx successful")) {
            diag "res = ", explain($res);
            goto END_TESTS;
        }


        if ($tsargs{prepare}) {
            #diag "Running prepare ...";
            $tsargs{prepare}->();
        }

        subtest "before setup" => sub {
            $chku->();
            done_testing;
        };
        goto END_TESTS unless Test::More->builder->is_passing;

        subtest "do (dry run)" => sub {
            my %fargs = (%$fargs,  -undo_action=>'do', -tx_manager=>$tm,
                         -dry_run=>1);
            $res = $func->(%fargs);
            if ($tsargs{dry_do_error}) {
                is($res->[0], $tsargs{dry_do_error},
                   "status is $tsargs{dry_do_error}");
                $exit++;
            } else {
                if (is($res->[0], 200, "status 200")) {
                    $chku->();
                    $undo_data = $res->[3]{undo_data};
                    ok($undo_data, "function returns undo_data");
                } else {
                    diag "res = ", explain($res);
                };
            }
            done_testing;
        };
        goto END_TESTS if $exit;
        goto END_TESTS unless Test::More->builder->is_passing;

        subtest "do" => sub {
            my %fargs = (%$fargs,  -undo_action=>'do', -tx_manager=>$tm);
            $res = $func->(%fargs);
            if ($tsargs{do_error}) {
                is($res->[0], $tsargs{do_error},
                   "status is $tsargs{do_error}");
                $exit++;
            } else {
                if (is($res->[0], 200, "status 200")) {
                    $chks->();
                    $undo_data = $res->[3]{undo_data};
                    ok($undo_data, "function returns undo_data");
                } else {
                    diag "res = ", explain($res);
                }
            }
            done_testing;
        };
        goto END_TESTS unless Test::More->builder->is_passing;

        subtest "repeat do -> noop (idempotent)" => sub {
            my %fargs = (%$fargs,  -undo_action=>'do', -tx_manager=>$tm);
            $res = $func->(%fargs);
            if (is($res->[0], 304, "status 304")) {
                $chks->();
            } else {
                diag "res = ", explain($res);
            }
            done_testing;
        };
        goto END_TESTS unless Test::More->builder->is_passing;

        if ($tsargs{set_state1} && $tsargs{check_state1}) {
            $tsargs{set_state1}->();
            subtest "undo after state changed" => sub {
                my %fargs = (%$fargs, -undo_action=>'undo', -tx_manager=>$tm,
                             -undo_data=>$undo_data);
                $res = $func->(%fargs);
                $tsargs{check_state1}->();
                done_testing;
            };
            goto END_TESTS;
        }

        subtest "undo (dry run)" => sub {
            my %fargs = (%$fargs, -undo_action=>'undo', -undo_data=>$undo_data,
                         -tx_manager=>$tm, -dry_run=>1);
            $res = $func->(%fargs);
            if (is($res->[0], 200, "status 200")) {
                $chks->();
            } else {
                diag "res = ", explain($res);
            }
            done_testing;
        };
        goto END_TESTS unless Test::More->builder->is_passing;

        subtest "undo" => sub {
            my %fargs = (%$fargs, -undo_action=>'undo', -undo_data=>$undo_data,
                         -tx_manager=>$tm);
            $res = $func->(%fargs);
            if (is($res->[0], 200, "status 200")) {
                $chku->();
                $redo_data = $res->[3]{undo_data};
                ok($redo_data, "function returns undo_data (for redo)");
            } else {
                diag "res = ", explain($res);
            }
            done_testing;
        };
        goto END_TESTS unless Test::More->builder->is_passing;

        # note: repeat undo is NOT guaranteed to be noop, not idempotent here
        # because we rely on undo data which will refuse to apply changes if
        # state has changed.

        if ($tsargs{set_state2} && $tsargs{check_state2}) {
            $tsargs{set_state2}->();
            subtest "redo after state changed" => sub {
                my %fargs = (%$fargs, -undo_action=>'undo',
                             -undo_data=>$redo_data, -tx_manager=>$tm);
                $res = $func->(%fargs);
                $tsargs{check_state2}->();
                done_testing;
            };
            goto END_TESTS;
        }

        subtest "redo (dry run)" => sub {
            my %fargs = (%$fargs, -undo_action=>'undo', -undo_data=>$redo_data,
                         -tx_manager=>$tm, -dry_run=>1);
            $res = $func->(%fargs);
            if (is($res->[0], 200, "status 200")) {
                $chku->();
            } else {
                diag "res = ", explain($res);
            }
            done_testing;
        };
        goto END_TESTS unless Test::More->builder->is_passing;

        subtest "redo" => sub {
            my %fargs = (%$fargs, -undo_action=>'undo', -undo_data=>$redo_data,
                         -tx_manager=>$tm);
            $res = $func->(%fargs);
            if (is($res->[0], 200, "status 200")) {
                $chks->();
                $undo_data2 = $res->[3]{undo_data};
                ok($undo_data2,"function returns undo_data (for undoing redo)");
            } else {
                diag "res = ", explain($res);
            }
            done_testing;
        };
        goto END_TESTS unless Test::More->builder->is_passing;

        # note: repeat redo is NOT guaranteed to be noop.

        subtest "undo redo (dry run)" => sub {
            my %fargs = (%$fargs, -undo_action=>'undo', -undo_data=>$undo_data2,
                         -tx_manager=>$tm, -dry_run=>1);
            $res = $func->(%fargs);
            if (is($res->[0], 200, "status 200")) {
                $chks->();
            } else {
                diag "res = ", explain($res);
            }
            done_testing;
        };
        goto END_TESTS unless Test::More->builder->is_passing;

        subtest "undo redo" => sub {
            my %fargs = (%$fargs, -undo_action=>'undo',
                         -undo_data=>$undo_data2, -tx_manager=>$tm);
            $res = $func->(%fargs);
            if (is($res->[0], 200, "status 200")) {
                $chku->();
                #$redo_data2 = $res->[3]{undo_data};
                #ok($redo_data2, "function returns undo_data");
            } else {
                diag "res = ", explain($res);
            }
            done_testing;
        };
        goto END_TESTS unless Test::More->builder->is_passing;

        # note: repeat undo redo is NOT guaranteed to be noop.

        ## can no longer be done, perigen-undo 0.25+ requires tx
        #subtest "normal (without undo) (dry run)" => sub {
        #    my %fargs = (%$fargs,
        #                 -dry_run=>1);
        #    $res = $func->(%fargs);
        #    $chku->();
        #    done_testing;
        #};
        #goto END_TESTS unless Test::More->builder->is_passing;
        #
        #subtest "normal (without undo)" => sub {
        #    my %fargs = (%$fargs);
        #    $res = $func->(%fargs);
        #    $chks->();
        #    done_testing;
        #};
        #goto END_TESTS unless Test::More->builder->is_passing;
        #
        #subtest "repeat normal -> noop (idempotent)" => sub {
        #    my %fargs = (%$fargs);
        #    $res = $func->(%fargs);
        #    $chks->();
        #    is($res->[0], 304, "status 304");
        #    done_testing;
        #};
        #goto END_TESTS unless Test::More->builder->is_passing;

      END_TESTS:
        if ($tsargs{cleanup}) {
            #diag "Running cleanup ...";
            $tsargs{cleanup}->();
        }
        done_testing;
    };
}

1;
# ABSTRACT: Test Setup::* modules


__END__
=pod

=head1 NAME

Test::Setup - Test Setup::* modules

=head1 VERSION

version 1.02

=head1 FUNCTIONS

=head2 test_setup(%args)

Test a setup function. Will call setup function several times to test dry run
and undo features.

Arguments (C<*> denotes required arguments):

=over 4

=item * name* => STR

The test name.

=item * function* => STR or CODE

The setup function to test.

=item * args* => HASH

Arguments to feed to setup function. Note that you should not add special
arguments like -dry_run, -undo_action, -undo_data because they will be added by
test_setup(). -undo_trash_dir can be passed, though.

=item * check_unsetup* => CODE

Supply code to check the condition before setup (or after undo). For example if
the setup function is setup_file, the code should check whether the file does
not exist.

Will be run before setup or after undo.

=item * check_setup => CODE

Supply code to check the set up condition. For example if the setup function is
setup_file, the code should check whether the file exists.

Will be run after do or redo.

=item * arg_error => BOOL (default 0)

If set to 1, test_setup() will just test whether setup function will return 4xx
status when fed with arguments.

=item * set_state1 => CODE (optional)

=item * check_state1 => CODE (optional)

If set, test_setup() will execute set_state1 after the 'do' action. The code is
supposed to change state (to a state called 'state1') so that the 'undo' step
will refuse to undo because state has changed.

If set, the 'undo' action should fail to perform undo (condition should still at
'state1', checked by check_state1). test_setup() will not perform the rest of
the tests after this (undo, redo, etc).

=item * set_state2 => CODE (optional)

=item * check_state2 => CODE (optional)

If set, test_setup() will execute set_state2 after the 'undo' action. The code
is supposed to change state (to a state called 'state2') so that the 'redo' step
will refuse to redo because state has changed.

If set, the 'redo' action should fail to perform redo (condition should still at
'state2', checked by check_state2). test_setup() will not perform the rest of
the tests after this (redo, etc).

=item * prepare => CODE (optional)

Code to run before calling any setup function.

=item * cleanup => CODE (optional)

Code to run after calling all setup function.

=back

=head1 AUTHOR

Steven Haryanto <stevenharyanto@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2012 by Steven Haryanto.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

