#!/usr/bin/env tclsh
package require Tcl 8.6 9

namespace eval ::lambda_package {
    variable root [file dirname [file dirname [file normalize [info script]]]]
}

# Materialize links: ZIP extraction must not depend on the build prefix.
proc ::lambda_package::copy_tree {source target {ancestors {}}} {
    while {[file type $source] eq "link"} {
        if {$source in $ancestors} {error "symlink cycle at $source"}
        lappend ancestors $source
        set source [file normalize [file join [file dirname $source] [file readlink $source]]]
    }
    if {$source in $ancestors} {error "symlink cycle at $source"}
    if {[file isdirectory $source]} {
        file mkdir $target
        foreach path [lsort [glob -nocomplain -directory $source * .*]] {
            set name [file tail $path]
            if {$name in {. .. .git .ttrek-git cmake pkgconfig} || [string match cmake-* $name]} {continue}
            copy_tree $path [file join $target $name] [linsert $ancestors end $source]
        }
    } elseif {[file isfile $source]} {
        if {[file extension $source] in {.a .la .h}} {return}
        file copy -force $source $target
    } else {error "not a regular file: $source"}
}

proc ::lambda_package::files {directory} {
    set result {}
    foreach path [lsort [glob -nocomplain -directory $directory * .*]] {
        if {[file tail $path] in {. ..}} {continue}
        if {[file isdirectory $path]} {
            lappend result {*}[files $path]
        } else {lappend result $path}
    }
    return $result
}

proc ::lambda_package::is_elf {path} {
    set channel [open $path rb]
    try {expr {[read $channel 4] eq "\x7fELF"}} finally {close $channel}
}

proc ::lambda_package::native_libraries {stage localOnly} {
    set queue [files [file join $stage local]]
    set architecture {}
    for {set i 0} {$i < [llength $queue]} {incr i} {
        set path [lindex $queue $i]
        if {![is_elf $path]} {continue}
        set header [exec env LC_ALL=C readelf -h $path]
        if {![regexp {Machine:\s+([^\n]+)} $header -> machine]} {error "cannot identify CPU: $path"}
        switch -glob -- [string trim $machine] {
            *X86-64 {set cpu x86_64}
            AArch64 {set cpu arm64}
            default {error "unsupported Lambda CPU: $machine ($path)"}
        }
        if {$architecture eq {}} {set architecture $cpu}
        if {$cpu ne $architecture} {error "mixed CPU architectures in $path"}
        if {!$localOnly} {
            set versions [exec env LC_ALL=C readelf --version-info $path]
            foreach {match version} [regexp -all -inline {GLIBC_([0-9]+\.[0-9]+)} $versions] {
                if {[package vcompare $version 2.34] > 0} {
                    error "$path requires GLIBC_$version; provided.al2023 supplies glibc 2.34. Rebuild the prefix on AL2023 for $cpu (or use --local-only for a local test)."
                }
            }
        }
        # ldd resolves the complete dependency closure. glibc and its loader are
        # provided by AL2023; other system libraries (e.g. libstdc++) travel with us.
        set status [catch {exec env LC_ALL=C \
            LD_LIBRARY_PATH=[file join $stage local lib]:[file join $stage local lib64] \
            ldd $path 2>@1} dependencies]
        if {$status && ![regexp {not a dynamic executable|statically linked} $dependencies]} {
            error "cannot resolve native libraries for $path: $dependencies"
        }
        foreach line [split $dependencies \n] {
            if {[string match {*=> not found*} $line]} {error "missing native dependency for $path: [string trim $line]"}
            if {![regexp {^\s*(\S+) => (/.+) \(0x[0-9a-f]+\)} $line -> name source]} {continue}
            if {[regexp {^lib(c|m|mvec|dl|pthread|rt|resolv|util|anl)\.so\.} $name]} {continue}
            if {[string first "$stage/" $source] == 0} {continue}
            set target [file join $stage local lib $name]
            if {![file exists $target]} {
                copy_tree $source $target
                lappend queue $target
            }
        }
    }
    return $architecture
}

proc ::lambda_package::main {arguments} {
    variable root
    set options [dict create --output [file join $root dist ttrek-sh.zip] \
        --prefix [file join $root ttrek-venv local] --tclsh {} \
        --content-dir [file join $root content] --s3-dir [file join $root dist s3]]
    if {[info exists ::env(TTREK_SITE_PREFIX)] && $::env(TTREK_SITE_PREFIX) ne {}} {
        dict set options --prefix $::env(TTREK_SITE_PREFIX)
    }
    set localOnly 0
    for {set i 0} {$i < [llength $arguments]} {incr i} {
        set key [lindex $arguments $i]
        if {$key in {--help -h}} {
            set channel [open [file join $root lambda package-usage.txt]]
            try {puts -nonewline [read $channel]} finally {close $channel}
            return
        }
        if {$key eq "--local-only"} {set localOnly 1; continue}
        if {![dict exists $options $key]} {error "unknown option: $key (see --help)"}
        if {[incr i] >= [llength $arguments]} {error "missing value for $key"}
        dict set options $key [lindex $arguments $i]
    }
    if {$::tcl_platform(os) ne "Linux"} {error "package on Linux with libraries built for Amazon Linux 2023"}
    foreach command {readelf ldd} {
        if {[auto_execok $command] eq {}} {error "$command is required"}
    }
    set prefix [file normalize [dict get $options --prefix]]
    set output [file normalize [dict get $options --output]]
    set seed [file normalize [dict get $options --s3-dir]]
    set interpreter [dict get $options --tclsh]
    if {$interpreter eq {}} {
        foreach name {tclsh9.1 tclsh9.0 tclsh8.7 tclsh8.6 tclsh} {
            if {[file executable [file join $prefix bin $name]]} {set interpreter $name; break}
        }
    }
    if {$interpreter eq {} || [file tail $interpreter] ne $interpreter ||
        ![file executable [file join $prefix bin $interpreter]]} {
        error "--prefix must contain a Tcl interpreter in bin/; --tclsh selects its filename"
    }
    set content [file normalize [dict get $options --content-dir]]
    foreach collection {docs} {
        if {![file isdirectory [file join $content $collection]]} {error "content directory must contain docs/"}
    }
    file mkdir [file dirname $output]
    set channel [file tempfile work [file join [file dirname $output] .lambda-XXXXXX]]
    close $channel
    file delete $work
    file mkdir $work
    set stage [file join $work task]
    try {
        file mkdir [file join $stage local bin] [file join $stage local lib]
        copy_tree [file join $prefix bin $interpreter] [file join $stage local bin tclsh]
        foreach directory {lib lib64} {
            if {[file isdirectory [file join $prefix $directory]]} {
                copy_tree [file join $prefix $directory] [file join $stage local $directory]
            }
        }
        set architecture [native_libraries $stage $localOnly]
        foreach path {tcl www schemas registry public LICENSE} {copy_tree [file join $root $path] [file join $stage $path]}
        file mkdir [file join $stage lambda]
        foreach name {runtime.tcl paths.tcl prepare.tcl} {
            file copy [file join $root lambda $name] [file join $stage lambda $name]
        }
        file copy [file join $root lambda bootstrap] [file join $stage bootstrap]
        copy_tree $content [file join $stage content]
        # Load only the staged site and packages. This catches missing/ABI-mismatched
        # extensions before we publish the ZIP, and imports into a new database.
        exec env -u TCLLIBPATH -u TCL_LIBRARY -u TCL_PACKAGE_PATH \
            LD_LIBRARY_PATH=[file join $stage local lib]:[file join $stage local lib64] \
            [file join $stage local bin tclsh] [file join $stage lambda prepare.tcl] >@stdout 2>@stderr
        file delete [file join $stage lambda prepare.tcl]
        set zip [file join $work site.zip]
        set candidates [list [info nameofexecutable] [file join $prefix bin $interpreter]]
        foreach name {tclsh9.1 tclsh9.0 tclsh8.7 tclsh8.6 tclsh} {
            if {[auto_execok $name] ne {}} {lappend candidates [lindex [auto_execok $name] 0]}
        }
        if {[info exists ::env(TCLZIPSH)] && $::env(TCLZIPSH) ne {}} {set candidates [list $::env(TCLZIPSH)]}
        set created 0
        foreach candidate [lsort -unique $candidates] {
            if {[catch {exec $candidate [file join $root bin zip-lambda.tcl] $zip $stage 2>@1} message options]} {
                set code [dict get $options -errorcode]
                if {[lindex $code 0] eq "CHILDSTATUS" && [lindex $code 2] == 3} {continue}
                error "zipfs packaging failed: $message"
            }
            set created 1
            break
        }
        if {!$created} {error "zipfs is unavailable. Install Tcl 9 or a Tcl 8 zipfs extension, or set TCLZIPSH."}
        # Seed data travels beside the archive; it contains public assets and a
        # local CLI build, never the host configuration or working databases.
        file mkdir $seed
        copy_tree [file join $root public] [file join $seed ttrek-assets]
        set cli [auto_execok ttrek]
        if {$cli eq {}} {error "ttrek is required to seed the local release download"}
        set target linux-[expr {$architecture eq "x86_64" ? "amd64" : "arm64"}]-glibc
        set release [file join $seed ttrek-local ttrek 1.0.0 $target]
        file mkdir $release
        file copy -force [lindex $cli 0] [file join $release ttrek]
        file rename -force $zip $output
        puts "Created $output ([file size $output] bytes); Tcl $interpreter, $architecture"
        puts "Set execute permissions for bootstrap and local/bin/tclsh with your deployment tooling."
        if {$localOnly} {puts "LOCAL TEST ONLY: AL2023 compatibility was not checked."}
    } finally {file delete -force $work}
}

if {[catch {::lambda_package::main $argv} message]} {
    puts stderr $message
    exit 1
}
