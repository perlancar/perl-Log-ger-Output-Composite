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
                no strict 'refs';

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
                    my $oconf = $ospec->{args} || {};
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
                    my $logger = $res or die "Hook from output module '$oname' ".
                        "didn't produce log routine";
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
                ${$varname} = $loggers;

                # generate logger routine
                my $logger;
                {
                    my @src;
                    push @src, "sub {\n";

                    #push @src, "  my $ctx = $_[0];\n";

                    # XXX filter by category_level

                    for my $i (0..$#ospecs) {
                        my $ospec = $ospecs[$i];
                        push @src, "  # output #$i: $ospec->{_name}\n";
                        push @src, "  {\n";
                        # XXX filter by output's category_level

                        # filter by output level
                        if (defined $ospec->{level}) {
                            push @src, "    last unless ".
                                Log::ger::Util::numeric_level($ospec->{level}).
                                  " >= $args{level};\n";
                        } else {
                            # filter by general level
                            push @src, "  last if \$Log::ger::Current_Level < $args{level};\n";
                        }

                        # run output's log routine
                        push @src, "    \$$varname\->[$i]->(\@_);\n";
                        push @src, "  } # output #$i\n\n";
                    }

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

=head1 SYNOPSIS

 use Log::ger::Output Composite => (
     outputs => {
         # single screen output
         Screen => {
             level => 'info', # set mper-output level. optional.
             args => { use_color=>1 },
         },
         # multiple file outputs
         File   => [
             {
                 level => 'warn',
                 # set per-category, per-output level. optional.
                 category_level => {
                     # don't log myapp.security messages to this file
                     'myapp.security' => 'off',
                 },
                 args => { path=>'/var/log/myapp.log' },
             },
             {
                 path => '/var/log/myapp-security.log',
                 level => 'off',
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

B<EARLY RELEASE>.

This is a L<Log::ger> output that can multiplex output to multiple outputs and
do filtering using per-category level, per-output level, or per-output
per-category level.


=head1 CONFIGURATION

=head2 outputs => hash

=head2 category_level => hash

=head2


=head1 TODO

Per-category level has not been implemented.

Per-output per-category level has not been implemented.


=head1 ENVIRONMENT


=head1 SEE ALSO

Modelled after L<Log::Any::App>.
