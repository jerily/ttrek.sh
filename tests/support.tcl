# Local integration-test utilities. No application services or AWS are shared.
package require Tcl 9.1
package require trequests 1.1.0
package require tjson
namespace eval ::test_support {
    variable jobs {}
    variable tick 0
}
proc ::test_support::assert {condition {message {assertion failed}}} {
    if {![uplevel 1 [list expr $condition]]} {error $message}
}
proc ::test_support::read_file {path} {
    set channel [open $path rb]
    try {read $channel} finally {close $channel}
}
proc ::test_support::write_file {path data} {
    file mkdir [file dirname $path]
    set channel [open $path wb]
    try {puts -nonewline $channel $data} finally {close $channel}
}
proc ::test_support::temporary {parent prefix} {
    file mkdir $parent
    set channel [file tempfile path [file join $parent $prefix]]
    close $channel
    file delete $path
    file mkdir $path
    return $path
}
proc ::test_support::ports {count} {
    set listeners {}
    set ports {}
    try {
        for {set i 0} {$i < $count} {incr i} {
            set listener [socket -server {apply {{channel args} {close $channel}}} -myaddr 127.0.0.1 0]
            lappend listeners $listener
            lappend ports [lindex [chan configure $listener -sockname] 2]
        }
        return $ports
    } finally {foreach listener $listeners {close $listener}}
}
proc ::test_support::pause {milliseconds} {
    variable tick
    after $milliseconds {incr ::test_support::tick}
    vwait ::test_support::tick
}
proc ::test_support::drain {channel} {
    variable jobs
    puts -nonewline [dict get $jobs $channel log] [read $channel]
    if {[eof $channel]} {
        fileevent $channel readable {}
        chan configure $channel -blocking 1
        set status [catch {close $channel} message]
        close [dict get $jobs $channel log]
        dict set jobs $channel finished 1
        dict set jobs $channel status $status
        dict set jobs $channel message $message
    }
}
proc ::test_support::start {command logPath {environment {}} {directory {}}} {
    variable jobs
    set launch [list {*}[auto_execok env]]
    dict for {key value} $environment {lappend launch $key=$value}
    # These integration services run on Linux; isolate their process group for cleanup.
    lappend launch {*}[auto_execok setsid] --wait {*}$command
    set previous [pwd]
    try {
        if {$directory ne {}} {cd $directory}
        set channel [open [list | {*}$launch 2>@1] r]
    } finally {cd $previous}
    chan configure $channel -blocking 0 -translation binary
    set log [open $logPath wb]
    dict set jobs $channel [dict create pid [lindex [pid $channel] 0] log $log finished 0]
    fileevent $channel readable [list ::test_support::drain $channel]
    return $channel
}
proc ::test_support::running {channel} {
    variable jobs
    update
    expr {![dict get $jobs $channel finished]}
}
proc ::test_support::stop {channel {timeout 30000}} {
    variable jobs
    if {$channel eq {} || ![running $channel]} {return}
    set process [dict get $jobs $channel pid]
    # Let the supervisor stop its own workers and remove service directories.
    catch {exec kill -TERM -- $process}
    set deadline [expr {[clock milliseconds] + $timeout}]
    while {[running $channel] && [clock milliseconds] < $deadline} {pause 20}
    if {[running $channel]} {
        catch {exec kill -KILL -- -$process}
        set deadline [expr {[clock milliseconds] + 5000}]
        while {[running $channel] && [clock milliseconds] < $deadline} {pause 20}
        error "process group $process did not shut down within $timeout ms"
    }
}
proc ::test_support::port_open {port} {
    if {[catch {socket 127.0.0.1 $port} channel]} {return 0}
    close $channel
    return 1
}
proc ::test_support::wait_port {port process} {
    for {set i 0} {$i < 100} {incr i} {
        assert {[running $process]} "process exited before port $port opened"
        if {[port_open $port]} {return}
        pause 100
    }
    error "timed out waiting for port $port"
}
proc ::test_support::request {url {status 200} {method GET} {data {}} {type application/octet-stream} {options {}}} {
    if {$method ni {GET HEAD}} {lappend options -data_binary $data -content_type $type}
    set response [::trequests::request $method $url -timeout 30000 -timeout_connect 1000 {*}$options]
    try {
        assert {[$response status_code] == $status} "$url: expected $status, got [$response status_code]: [$response error]"
        set headers {}
        foreach {key value} [$response headers] {dict set headers [string tolower $key] $value}
        return [dict create body [$response content] headers $headers status [$response status_code]]
    } finally {$response destroy}
}
proc ::test_support::json {response} {
    ::tjson::json_to_simple [encoding convertfrom utf-8 [dict get $response body]]
}
proc ::test_support::sha256 {data} {
    # OpenSSL is already a site dependency; use its native digest for large ZIPs.
    set channel [open [list | {*}[auto_execok openssl] dgst -sha256] r+]
    chan configure $channel -translation binary
    try {
        puts -nonewline $channel $data
        chan close $channel write
        set output [read $channel]
    } finally {close $channel}
    if {![regexp {([a-f0-9]{64})\s*$} $output -> digest]} {error {invalid OpenSSL digest}}
    return $digest
}
proc ::test_support::contains {response text} {
    expr {[string first $text [dict get $response body]] >= 0}
}
