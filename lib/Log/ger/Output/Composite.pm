package Log::ger::Output::Composite;

# DATE
# VERSION

use strict;
use warnings;

sub get_hooks {
    my %conf = @_;

    my @ospecs;
    {
        my $outputs = $conf{outputs};
        for my $oname (sort keys %$outputs) {
            my $ospec0 = $outputs->{$oname};
            my @ospecs0;
            if (ref $ospec0 eq 'ARRAY') {
                @ospecs0 = map { +{ %{$_} } } @$ospec0;
            } else {
                @ospecs0 = (+{ %{ $ospec0 } });
            }

            die "Invalid output name '$oname'"
                unless $oname =~ /\A\w+(::\w+)*\z/;
            my $mod = "Log::ger::Output::$oname";
            (my $mod_pm = "$mod.pm") =~ s!::!/!g;
            require $mod_pm;
            for my $ospec (@ospecs0) {
                $ospec->{_name} = $oname;
                $ospec->{_mod} = $mod;
                push @ospecs, $ospec;
            }
        }
    }

    return {
        'create_log_routine' => [
            # install at very high priority (5) to override the default Log::ger
            # behavior (at priority 10) that installs null routines to high
            # levels. so we handle all levels.
            __PACKAGE__, 5,
            sub {
                require Data::Dmp;

                my %args = @_;

                my $target = $args{target};
                my $target_arg = $args{target_arg};

                my ($saved_g, $saved_pt);
                my $loggers = [];
                # extract the code from each output module's hook, collect them
                # and call them all in our code
                for my $ospec (@ospecs) {
                    my $oname = $ospec->{_name};
                    my $saved0;
                    $saved0 = Log::ger::Util::empty_hooks('create_log_routine');
                    $saved_g ||= $saved0;
                    if (defined $target) {
                        $saved0 = Log::ger::Util::empty_per_target_hooks(
                            $target, $target_arg, 'create_log_routine');
                        $saved_pt ||= $saved0;
                    }
                    my $oconf = $ospec->{conf} || {};
                    Log::ger::Util::set_plugin(
                        name => $oname,
                        prefix => 'Log::ger::Output::',
                        conf => $oconf,
                        target => $target,
                        target_arg => $target_arg,
                    );
                    my $res = Log::ger::run_hooks(
                        'create_log_routine', \%args, 1, $target, $target_arg,
                    );
                    my $logger = $res or die "Hook from output module ".
                        "'$oname' didn't produce log routine";
                    push @$loggers, $logger;
                }
                Log::ger::Util::restore_hooks('create_log_routine', $saved_g)
                      if $saved_g;
                Log::ger::Util::restore_per_target_hooks(
                    $target, $target_arg, 'create_log_routine', $saved_pt)
                      if $saved_pt;
                unless (@$loggers) {
                    $Log::err::_logger_is_null = 1;
                    return [sub {0}];
                }

                # put the codes in a package so it's addressable from
                # string-eval'ed code
                my ($addr) = "$loggers" =~ /\(0x(\w+)/;
                my $varname = "Log::ger::Stash::$addr";
                { no strict 'refs'; ${$varname} = $loggers; }

                # generate logger routine
                my $logger;
                {
                    my @src;
                    push @src, "sub {\n";

                    #push @src, "  my $ctx = $_[0];\n";

                    for my $i (0..$#ospecs) {
                        my $ospec = $ospecs[$i];
                        push @src, "  # output #$i: $ospec->{_name}\n";
                        push @src, "  {\n";

                        # XXX filter by output's category_level
                        if ($ospec->{category_level}) {
                            push @src, "    my \$cat = \$_[0]{category} || ".
                                "'';\n";
                            for my $cat (sort {length($b) <=> length($a)}
                                             keys %{$ospec->{category_level}}) {
                                my $clevel = $ospec->{category_level}{$cat};
                                push @src, "    if (\$cat eq ".Data::Dmp::dmp($cat)." || index(\$cat, ".Data::Dmp::dmp("$cat\::").") == 0) { ";

                                push @src, " }\n";
                            }
                        }

                        # filter by output level
                        my ($omin_level, $omax_level);
                        if (defined $ospec->{level}) {
                            $omin_level = Log::ger::Util::numeric_level(
                                $ospec->{level});
                            $omax_level = Log::ger::Util::numeric_level(
                                'fatal');
                            ($omin_level, $omax_level) =
                                ($omax_level, $omin_level)
                                if $omin_level > $omax_level;
                        }
                        if (defined $ospec->{min_level} ||
                                defined $ospec->{max_level}) {
                            my $omin = Log::ger::Util::numeric_level(
                                $ospec->{min_level});
                            my $omax = Log::ger::Util::numeric_level(
                                $ospec->{max_level});
                            ($omin, $omax) = ($omax, $omin) if $omin > $omax;
                            $omin_level = $omin if
                                !defined($omin_level) || $omin_level < $omin;
                            $omax_level = $omax if
                                !defined($omax_level) || $omax_level > $omin;
                        }
                        if (defined $omin_level) {
                            push @src, "    last unless ".
                                "$args{level} >= $omin_level && ".
                                "$args{level} <= $omax_level;\n";
                        } else {
                            # filter by general level
                            push @src, "    last if ".
                                "\$Log::ger::Current_Level < $args{level};\n";
                        }

                        # run output's log routine
                        push @src, "    \$$varname\->[$i]->(\@_);\n";
                        push @src, "  }\n";
                        push @src, "  # end output #$i\n\n";
                    }

                    push @src, "};\n";
                    my $src = join("", @src);
                    print "D: src for log_$args{str_level}: <<$src>>\n";

                    $logger = eval $src;
                }
                [$logger];
            }]
    };
}

1;
# ABSTRACT: Composite output

=for Pod::Coverage ^(.+)$

=head1 SYNOPSIS

 use Log::ger::Output Composite => (
     outputs => {
         # single screen output
         Screen => {
             level => 'info', # set mper-output level. optional.
             conf => { use_color=>1 },
         },
         # multiple file outputs
         File   => [
             {
                 conf => { path=>'/var/log/myapp.log' },
                 level => 'warn',
                 # set per-category, per-output level. optional.
                 category_level => {
                     # don't log myapp.security messages to this file
                     'myapp.security' => 'off',
                 },
             },
             {
                 conf => { path => '/var/log/myapp-security.log' },
                 level => 'warn',
                 category_level => {
                     # only myapp.security messages go to this file
                     'myapp.security' => 'warn',
                 },
             },
         ],
     },
     # set per-category level. optional.
     category_level => {
        'category1.sub1' => 'info',
        'category2' => 'debug',
        ...
     },
 );
 use Log::ger;

 log_warn "blah...";


=head1 DESCRIPTION

This is a L<Log::ger> output that can multiplex output to several outputs and do
filtering per-category level, per-output level, or per-output per-category
level.


=head1 CONFIGURATION

=head2 outputs => hash

Specify outputs. It's a hash with output name as keys and output specification
as values.

Output name is the name of output module without the C<Log::ger::Output::>
prefix, e.g. L<Screen|Log::ger::Output::Screen> or
L<File||Log::ger::Output::File>.

Output specification is either a hashref or arrayref of hashrefs to specify
multiple outputs per type (e.g. if you want to output to two File's). Known
hashref keys:

=over

=item * conf => hashref

Specify output configuration. See each output documentation for the list of
available configuration parameters.

=item * level => str|int

Specify per-output level. If specified, logging will be done at this level
instead of the general level. For example, if this is set to C<debug> then debug
messages and higher will be sent to output even though the general level is
C<warn>. Vice versa, if this is set to C<error> then even though the general
level is C<warn>, warning messages won't be sent to this output; only C<error>
messages and higher will be sent.

=item * min_level => str|int

=item * max_level => str|int

As an alternative to setting C<level>, you can set C<min_level> and C<max_level>
instead. This also sets per-output level. Setting C<level> to C<info> is
actually equivalent to:

 min_level => 'info'
 max_level => 'trace'

If you accidentally mix up min_level and max_level, this module will helpfully
fix it for you.

=back

=head2 category_level => hash

=head2


=head1 TODO

Per-category level has not been implemented.

Per-output per-category level has not been implemented.


=head1 ENVIRONMENT


=head1 SEE ALSO

Modelled after L<Log::Any::App>.
