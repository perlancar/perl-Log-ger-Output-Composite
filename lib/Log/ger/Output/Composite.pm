package Log::ger::Output::Composite;

# DATE
# VERSION

use strict;
use warnings;

sub _get_min_max_level {
    my $level = shift;
    my ($min, $max);
    if (defined $level) {
        if (ref $level eq 'ARRAY') {
            $min = Log::ger::Util::numeric_level($level->[0]);
            $max = Log::ger::Util::numeric_level($level->[1]);
            ($min, $max) = ($max, $min) if $min > $max;
        } else {
            $min = 0;
            $max = Log::ger::Util::numeric_level($level);
        }
    }
    ($min, $max);
}

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
                no strict 'refs';
                require Data::Dmp;

                my %args = @_;

                my $target = $args{target};
                my $target_arg = $args{target_arg};

                my $loggers = [];
                for my $ospec (@ospecs) {
                    my $oname = $ospec->{_name};
                    my $mod = "Log::ger::Output::$oname";
                    my $hooks = &{"$mod\::get_hooks"}(%{ $ospec->{conf} || {} })
                        or die "Output module $mod does not return any hooks";
                    $hooks->{create_log_routine}
                        or die "Output module $mod does not declare ".
                        "create_log_routine hook";
                    my @hook_args = (
                        target => $args{target},
                        target_arg => $args{target_arg},
                        init_args => $args{init_args},
                        level => $args{level},
                    );
                    my $res = $hooks->{create_log_routine}->[2]->(@hook_args)
                        or die "Hook from output module $mod does not produce ".
                        "log routine";
                    ref $res->[0] eq 'CODE'
                        or die "Logger from output module $mod ".
                        "is not a coderef";
                    push @$loggers, $res->[0];
                }
                unless (@$loggers) {
                    $Log::err::_logger_is_null = 1;
                    return [sub {0}];
                }

                # put the codes in a package so it's addressable from
                # string-eval'ed code
                my ($addr) = "$loggers" =~ /\(0x(\w+)/;
                my $varname = "Log::ger::Stash::$addr";
                { no strict 'refs'; ${$varname} = $loggers; }

                # generate our logger routine
                my $logger;
                {
                    my @src;
                    push @src, "sub {\n";

                    for my $i (0..$#ospecs) {
                        my $ospec = $ospecs[$i];
                        push @src, "  # output #$i: $ospec->{_name}\n";
                        push @src, "  {\n";

                        # filter by output's category_level and category-level
                        if ($ospec->{category_level} || $conf{category_level}) {
                            push @src, "    my \$cat = \$_[0]{category} || ".
                                "'';\n";

                            my @cats;
                            if ($ospec->{category_level}) {
                                for my $cat (keys %{$ospec->{category_level}}) {
                                    my $clevel = $ospec->{category_level}{$cat};
                                    push @cats, [$cat, 1, $clevel];
                                }
                            }
                            if ($conf{category_level}) {
                                for my $cat (keys %{$conf{category_level}}) {
                                    my $clevel = $conf{category_level}{$cat};
                                    push @cats, [$cat, 2, $clevel];
                                }
                            }

                            for my $cat (sort {
                                length($b->[0]) <=> length($a->[0]) ||
                                    $a->[0] cmp $b->[0] ||
                                        $a->[1] <=> $b->[1]} @cats) {
                                push @src, "    if (\$cat eq ".Data::Dmp::dmp($cat->[0])." || index(\$cat, ".Data::Dmp::dmp("$cat->[0]\::").") == 0) { ";
                                my ($min_level, $max_level) =
                                    _get_min_max_level($cat->[2]);
                                push @src, "if ($args{level} >= $min_level && ".
                                    "$args{level} <= $max_level) { goto L } else { last }";
                                push @src, " }\n";
                            }
                            push @src, "\n";
                        }

                        # filter by output level
                        my ($min_level, $max_level) = _get_min_max_level(
                            $ospec->{level});
                        if (defined $min_level) {
                            push @src, "    if ($args{level} >= $min_level && ".
                                "$args{level} <= $max_level) { goto L } else { last }\n";
                        }

                        # filter by general level
                        push @src, "    if (\$Log::ger::Current_Level >= $args{level}) { goto L } else { last }\n";

                        # run output's log routine
                        push @src, "    L: \$$varname\->[$i]->(\@_);\n";
                        push @src, "  }\n";
                        push @src, "  # end output #$i\n\n";
                    } # for ospec

                    push @src, "};\n";
                    my $src = join("", @src);
                    #print "D: src for log_$args{str_level}: <<$src>>\n";

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
             level => 'info', # set per-output level. optional.
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
                     'MyApp::Security' => 'off',
                 },
             },
             {
                 conf => { path => '/var/log/myapp-security.log' },
                 level => 'warn',
                 category_level => {
                     # only myapp.security messages go to this file
                     'MyApp::Security' => 'warn',
                 },
             },
         ],
     },
     # set per-category level. optional.
     category_level => {
        'MyApp::SubModule1' => 'info',
        'MyApp::SubModule2' => 'debug',
        ...
     },
 );
 use Log::ger;

 log_warn "blah...";


=head1 DESCRIPTION

This is a L<Log::ger> output that can multiplex output to several outputs and do
filtering on the basis of per-category level, per-output level, or per-output
per-category level.


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

=item * level => str|int|[min, max]

Specify per-output level. If specified, logging will be done at this level
instead of the general level. For example, if this is set to C<debug> then debug
messages and higher will be sent to output even though the general level is
C<warn>. Vice versa, if this is set to C<error> then even though the general
level is C<warn>, warning messages won't be sent to this output; only C<error>
messages and higher will be sent.

You can specify a single level (e.g. 1 or "trace") or a two-element array to
specify minimum and maximum level (e.g. C<<["trace", "info"]>>). If you
accidentally mix up minimum and maximum, this module will helpfully fix it for
you.

=item * category_level => hash

Specify per-output per-category level. Hash key is category name, value is level
(which can be a string/numeric level or a two-element array containing minimum
and maximum level).

=back

=head2 category_level => hash

Specify per-category level. Hash key is category name, value is level (which can
be a string/numeric level or a two-element array containing minimum and maximum
level).


=head1 ENVIRONMENT


=head1 SEE ALSO
