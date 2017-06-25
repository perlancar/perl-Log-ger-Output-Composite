#!perl

use strict;
use warnings;
use Test::More 0.98;

use Log::ger::Output ();
use Log::ger::Util;

package My::P1; use Log::ger;
package My::P1::P2; use Log::ger;
package My::P1::P2::P3; use Log::ger;
package My::P1::P4; use Log::ger;
package My::P5; use Log::ger;

package main;

subtest "basics" => sub {
    my $str1 = "";
    my $str2 = "";
    Log::ger::Output->set(
        'Composite',
        outputs=>{
            String=>[
                {conf=>{string=>\$str1}},
                {conf=>{string=>\$str2}},
            ],
        });
    My::P1::log_warn("warn");
    My::P1::log_debug("debug");
    is($str1, "warn\n");
    is($str2, "warn\n");
};

subtest "per-output level" => sub {
    my $str1 = "";
    my $str2 = "";
    my $str3 = "";
    Log::ger::Output->set(
        'Composite',
        outputs=>{
            String=>[
                {conf=>{string=>\$str1}},
                {level=>"info", conf=>{string=>\$str2}},
                {level=>"error", conf=>{string=>\$str3}},
            ],
        });
    My::P1::log_debug("debug");
    My::P1::log_info("info");
    My::P1::log_warn("warn");
    My::P1::log_error("error");
    is($str1, "warn\nerror\n");
    is($str2, "info\nwarn\nerror\n");
    is($str3, "error\n");

    $str1 = $str2 = $str3 = "";
    Log::ger::Util::set_level("info");
    My::P1::log_debug("debug");
    My::P1::log_info("info");
    My::P1::log_warn("warn");
    My::P1::log_error("error");
    is($str1, "info\nwarn\nerror\n");
    is($str2, "info\nwarn\nerror\n");
    is($str3, "error\n");
};

subtest "per-output min_level & max_level" => sub {
    my $str1 = "";
    my $str2 = "";
    my $str3 = "";
    Log::ger::Output->set(
        'Composite',
        outputs=>{
            String=>[
                {conf=>{string=>\$str1}},
                {min_level=>"debug", max_level=>"info", conf=>{string=>\$str2}},
                {min_level=>"fatal", max_level=>"error", conf=>{string=>\$str3}},
            ],
        });
    Log::ger::Util::set_level("warn");
    My::P1::log_trace("trace");
    My::P1::log_debug("debug");
    My::P1::log_info("info");
    My::P1::log_warn("warn");
    My::P1::log_error("error");
    My::P1::log_fatal("fatal");
    is($str1, "warn\nerror\nfatal\n");
    is($str2, "debug\ninfo\n");
    is($str3, "error\nfatal\n");
};

subtest "per-category level" => sub {
    my $str1 = "";
    Log::ger::Output->set(
        'Composite',
        outputs=>{
            String=>[
                {
                    conf => {string=>\$str1},
                    category_level => {
                        'My::P1' => 'debug',
                        'My::P1::P2' => 'fatal',
                        'My::P1::P2::P3' => 'info',
                        'My::P1::P4' => 'info',
                        'My::P5' => 'error',
                    },
                },
            ],
        });
    Log::ger::Util::set_level("warn");
    for my $pkg (qw/My::P1 My::P1::P2 My::P1::P2::P3 My::P1::P4 My::P5/) {
        no strict 'refs';
        &{"$pkg\::log_trace"}("trace $pkg");
        &{"$pkg\::log_debug"}("debug $pkg");
        &{"$pkg\::log_info"}("info $pkg");
        &{"$pkg\::log_warn"}("warn $pkg");
        &{"$pkg\::log_error"}("error $pkg");
        &{"$pkg\::log_fatal"}("fatal $pkg");
    }
    diag $str1;
};

# XXX test filtering: per-output per-category level
# XXX test filtering: per-category level

done_testing;
