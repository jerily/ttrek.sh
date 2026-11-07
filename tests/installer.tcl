# Run the real installer against Tcl mocks and disposable installation homes.
package require Tcl 8.6 9
package require tcltest 2
namespace import ::tcltest::test

namespace eval ::installer_test {
    variable output
    variable done
}

proc ::installer_test::read_output {channel} {
    variable output
    variable done
    append output [read $channel]
    if {[eof $channel]} {set done complete}
}

proc ::installer_test::run {command} {
    variable output {}
    variable done {}
    set channel [open [list | {*}$command 2>@1] r]
    chan configure $channel -blocking 0
    fileevent $channel readable [list ::installer_test::read_output $channel]
    set timer [after 10000 {set ::installer_test::done timeout}]
    try {
        vwait ::installer_test::done
        if {$done eq "timeout"} {
            catch {exec kill -KILL {*}[pid $channel]}
            error "installer timed out: $output"
        }
        chan configure $channel -blocking 1
        if {[catch {close $channel} message]} {error "installer failed: $message\n$output"}
    } finally {
        after cancel $timer
        catch {close $channel}
    }
    return $output
}

proc ::installer_test::read_file {path} {
    set channel [open $path rb]
    try {read $channel} finally {close $channel}
}

set sourceRoot [file dirname [file dirname [file normalize [info script]]]]
set channel [file tempfile temporary]
close $channel
file delete $temporary
file mkdir $temporary
set tools [file join $temporary bin]
file mkdir $tools
set fixture [file join $sourceRoot tests fixtures installer-mock.tcl]
set envCommand [auto_execok env]
set failed 0
try {
    # Restrict the child PATH so host curl/wget installations cannot affect selection.
    foreach command {mktemp chmod mkdir rm rmdir cp grep head tail cut} {
        set executable [auto_execok $command]
        if {$executable eq {}} {error "missing test prerequisite: $command"}
        file link -symbolic [file join $tools $command] [lindex $executable 0]
    }
    foreach name {uname ldd sysctl sw_vers} {
        file copy $fixture [file join $tools $name]
        file attributes [file join $tools $name] -permissions 0755
    }
    ::tcltest::testConstraint linuxProc [expr {[file exists /proc/self/exe] && [file type /proc/self/exe] eq "link"}]
    set cases {
        {Linux x86_64 glibc 0 x86_64-unknown-linux-gnu}
        {Linux aarch64 glibc 0 aarch64-unknown-linux-gnu}
        {Linux x86_64 musl 0 x86_64-unknown-linux-musl}
        {Linux aarch64 musl 0 aarch64-unknown-linux-musl}
        {Darwin arm64 {} 1 aarch64-apple-darwin}
        {Darwin x86_64 {} 0 x86_64-apple-darwin}
        {Darwin x86_64 {} 1 aarch64-apple-darwin}
    }
    foreach client {curl wget} {
        set other [expr {$client eq "curl" ? "wget" : "curl"}]
        file delete -force [file join $tools $other]
        file copy -force $fixture [file join $tools $client]
        file attributes [file join $tools $client] -permissions 0755
        set number 0
        foreach case $cases {
            lassign $case system cpu libc arm64 triple
            set installHome [file join $temporary "$client [incr number]"]
            file mkdir $installHome
            set command [list {*}$envCommand -u TTREK_UPDATE_ROOT -u TTREK_HOME -u ENV \
                PATH=$tools HOME=$installHome TEST_OS=$system TEST_CPU=$cpu \
                TEST_LIBC=$libc TEST_ARM64=$arm64 TEST_TCLSH=[info nameofexecutable] \
                TEST_DOWNLOAD=[file join $installHome download.args]]
            foreach mode {production override local} {
                set invocation $command
                switch $mode {
                    production {set base https://ttrek.sh}
                    override {
                        lappend invocation TTREK_UPDATE_ROOT=https://localhost:4433/
                        set base https://localhost:4433
                    }
                    local {
                        lappend invocation ENV=LOCAL
                        set base http://localhost:8080
                    }
                }
                lappend invocation /bin/sh [file join $sourceRoot public ttrek-init] -y
                test installer-$client-$number-$mode "$client $system/$cpu ($libc, native ARM64=$arm64), $mode URL" \
                    -constraints [expr {$system eq "Linux" ? "linuxProc" : ""}] -body {
                        ::installer_test::run $invocation
                        set arguments [::installer_test::read_file [file join $installHome download.args]]
                        set binary [file join $installHome .ttrek bin ttrek]
                        if {"$base/dist/$triple/ttrek" ni $arguments} {error "wrong download URL: $arguments"}
                        if {"-k" in $arguments || "--no-check-certificate" in $arguments} {error "TLS verification disabled"}
                        if {$client eq "curl" && "--location" ni $arguments} {error "curl must follow redirects"}
                        if {$mode eq "local"} {
                            if {$client eq "curl"} {
                                set position [lsearch -exact $arguments --proto]
                                if {$position < 0 || [lindex $arguments [expr {$position + 1}]] ne "=https,http"} {
                                    error "LOCAL curl must allow HTTP: $arguments"
                                }
                            } elseif {"--https-only" in $arguments} {error "LOCAL wget must allow HTTP"}
                        }
                        list [::installer_test::read_file $binary] \
                            [expr {([file attributes $binary -permissions] & 0100) != 0}]
                    } -result {{ttrek test distribution} 1}
            }
        }
    }
    set failed $::tcltest::numTests(Failed)
} finally {
    file delete -force $temporary
    ::tcltest::cleanupTests
}
exit [expr {$failed > 0}]
