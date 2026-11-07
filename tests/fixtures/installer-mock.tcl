#!/bin/sh
# Launch with the test's interpreter even when its path contains spaces. \
exec "$TEST_TCLSH" "$0" "$@"

# Mock platform tools and downloaders; never make network requests.
switch -- [file tail $argv0] {
    uname {
        switch -- [lindex $argv 0] {
            -s {puts $::env(TEST_OS)}
            -m {puts $::env(TEST_CPU)}
            -o {puts GNU/Linux}
            default {error "unexpected uname arguments: $argv"}
        }
    }
    ldd {puts $::env(TEST_LIBC)}
    sysctl {puts "[lindex $argv 0]: $::env(TEST_ARM64)"}
    sw_vers {puts 14.0}
    curl - wget {
        if {"--help" in $argv} {
            puts {--proto --tlsv1.2 --ciphers --retry --continue-at --https-only --secure-protocol}
        } elseif {"-V" in $argv} {
            puts [expr {[file tail $argv0] eq "curl" ? "curl 8.7.1 OpenSSL/3.0" : "GNU Wget 1.21"}]
        } else {
            # A Tcl list records exact argument boundaries without a JSON dependency.
            set channel [open $::env(TEST_DOWNLOAD) w]
            puts $channel $argv
            close $channel
            set flag [expr {"--output" in $argv ? "--output" : "-O"}]
            set position [lsearch -exact $argv $flag]
            if {$position < 0 || $position + 1 >= [llength $argv]} {
                error "missing download destination: $argv"
            }
            set channel [open [lindex $argv [expr {$position + 1}]] wb]
            puts -nonewline $channel {ttrek test distribution}
            close $channel
        }
    }
    default {error "unexpected mock tool: $argv0"}
}
