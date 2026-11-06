#!/usr/bin/env tclsh
package require Tcl 8.6 9

namespace eval ::site_local {
    variable root [file dirname [file dirname [file normalize [info script]]]]
}

proc ::site_local::read_text {path} {
    set channel [open $path r]
    try {fconfigure $channel -encoding utf-8; read $channel} finally {close $channel}
}

proc ::site_local::write_text {path text} {
    set channel [open $path w]
    try {fconfigure $channel -encoding utf-8; puts $channel $text} finally {close $channel}
}

proc ::site_local::options {arguments} {
    variable root
    set options [dict create --zip [file join $root dist ttrek-sh.zip] \
        --routes [file join $root routes.json] --state-dir [file join $root var local] \
        --port 8080 --lambda-port 3001 --lambda-workers 4 --worker-threads 2 \
        --s3-port 3015 --s3-dir [file join $root dist s3]]
    foreach {name key} {TTREK_SITE_ZIP --zip TTREK_SITE_PORT --port \
        TTREK_LAMBDA_PORT --lambda-port TTREK_LOCAL_DIR --state-dir} {
        if {[info exists ::env($name)] && $::env($name) ne {}} {dict set options $key $::env($name)}
    }
    for {set i 0} {$i < [llength $arguments]} {incr i} {
        set key [lindex $arguments $i]
        if {![dict exists $options $key]} {error "unknown option: $key (see --help)"}
        if {[incr i] >= [llength $arguments]} {error "missing value for $key"}
        dict set options $key [lindex $arguments $i]
    }
    foreach {key maximum} {--port 65535 --lambda-port 65535 --s3-port 65535 --lambda-workers 128 --worker-threads 64} {
        set value [dict get $options $key]
        if {![string is integer -strict $value] || $value < 1 || $value > $maximum} {error "invalid $key"}
    }
    set ports [list [dict get $options --port] [dict get $options --lambda-port] [dict get $options --s3-port]]
    if {[llength [lsort -unique $ports]] != 3} {error "proxy, Lambda and S3 ports must differ"}
    foreach key {--zip --routes --state-dir --s3-dir} {
        if {[dict get $options $key] eq {}} {error "$key cannot be empty"}
        dict set options $key [file normalize [dict get $options $key]]
    }
    return $options
}

proc ::site_local::load_app {mode} {
    variable root
    set prefix $::env(TTREK_SITE_PREFIX)
    set ::auto_path [concat [list [file join $prefix lib] [file join $prefix lib64] \
        [file dirname $root]] $::auto_path]
    set override MOCK_[string toupper $mode]_APP
    if {[info exists ::env($override)] && $::env($override) ne {}} {
        set directory [file normalize $::env($override)]
        if {[file isfile $directory]} {set directory [file dirname $directory]}
        if {![file isfile [file join $directory pkgIndex.tcl]]} {error "$override must identify a mock-$mode-app package"}
        set ::auto_path [linsert $::auto_path 0 $directory]
    }
    if {[catch {package require mock-$mode-app 0.1.0} message]} {
        error "Cannot load mock-$mode-app: $message. Install the development dependencies or set $override."
    }
}

proc ::site_local::extract {archive directory} {
    if {![file isfile $archive]} {error "site ZIP does not exist: $archive; run ttrek run -script package -- --local-only"}
    if {![llength [info commands ::zipfs]]} {catch {package require zipfs}}
    if {![llength [info commands ::zipfs]]} {error "local extraction needs zipfs; select a Tcl 9 interpreter with TCLSH"}
    set mount [zipfs mount $archive ttrek-sh-[pid]]
    try {
        # Inspect every archive name before writing. Reject traversal and drive
        # paths rather than letting an archive write outside its extraction.
        set entries {}
        foreach path [zipfs list] {
            if {[string first "$mount/" $path] != 0 || [file isdirectory $path]} {continue}
            set name [string range $path [expr {[string length $mount] + 1}] end]
            if {[file pathtype $name] ne "relative" || [string first \\ $name] >= 0 ||
                [string first : $name] >= 0 || ".." in [file split $name]} {error "unsafe ZIP entry: $name"}
            lappend entries $path $name
        }
        foreach {path name} $entries {
            set destination [file join $directory $name]
            file mkdir [file dirname $destination]
            file copy $path $destination
        }
    } finally {zipfs unmount $mount}
    foreach name {bootstrap local/bin/tclsh lambda/runtime.tcl data/docs.sqlite3} {
        if {![file isfile [file join $directory $name]]} {error "site ZIP is missing $name"}
    }
    # Local execution is explicitly authorized; the original ZIP is untouched.
    foreach name {bootstrap local/bin/tclsh} {file attributes [file join $directory $name] -permissions 0o755}
}

proc ::site_local::main {mode arguments} {
    variable root
    if {$mode ni {lambda proxy s3}} {error "expected lambda, proxy or s3"}
    if {"--help" in $arguments || "-h" in $arguments} {
        puts -nonewline [read_text [file join $root lambda local-usage.txt]]
        return
    }
    set options [options $arguments]
    load_app $mode
    set parent [dict get $options --state-dir]
    file mkdir $parent
    set channel [file tempfile work [file join $parent $mode]]
    close $channel
    file delete $work
    file mkdir $work
    try {
        set common [list --host 127.0.0.1 --worker-threads [dict get $options --worker-threads]]
        if {$mode eq "lambda"} {
            extract [dict get $options --zip] [file join $work task]
            set ::env(TTREK_LOCAL_RUNTIME_DATA) [file join $work data]
            set ::env(TTREK_LOCAL_S3_ENDPOINT) http://127.0.0.1:[dict get $options --s3-port]
            foreach binary [glob -nocomplain -directory [dict get $options --s3-dir] ttrek-local/ttrek/1.0.0/*/ttrek] {
                set ::env(TTREK_LOCAL_RELEASE_TARGET) [file tail [file dirname $binary]]
                set ::env(TTREK_LOCAL_RELEASE_SHA256) [lindex [exec sha256sum $binary] 0]
                break
            }
            file copy [file join $root lambda local-template.json] [file join $work template.json]
            ::mock::lambda::main [concat $common [list --template [file join $work template.json] \
                --port [dict get $options --lambda-port] --lambda-workers [dict get $options --lambda-workers]]]
        } elseif {$mode eq "s3"} {
            if {![file isdirectory [dict get $options --s3-dir]]} {error "S3 seed directory is missing; run the package script first"}
            ::mock::s3::main [list --host 127.0.0.1 --port [dict get $options --s3-port] \
                --db-path [file join $work objects.sqlite3] --data-dir [dict get $options --s3-dir]]
        } else {
            # Preserve route JSON types while changing only the local endpoint.
            lassign [::tjson::json_to_typed [read_text [dict get $options --routes]]] type routes
            if {$type ne "M"} {error "routes must contain a JSON object"}
            dict set routes lambdaEndpoint [list S http://127.0.0.1:[dict get $options --lambda-port]]
            write_text [file join $work routes.json] [::tjson::typed_to_json [list M $routes]]
            ::mock::proxy::main [concat $common [list --config [file join $work routes.json] \
                --port [dict get $options --port]]]
        }
    } finally {file delete -force $work}
}

if {[catch {::site_local::main [lindex $argv 0] [lrange $argv 1 end]} message]} {
    puts stderr "ttrek-sh local: $message"
    exit 1
}
