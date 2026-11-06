#!/usr/bin/env tclsh
package require Tcl 8.6 9

if {![llength [info commands ::zipfs]] && ![llength [info commands ::zipfs::mkzip]]} {
    catch {package require zipfs}
}
if {[llength [info commands ::zipfs]]} {
    set mkzip {::zipfs mkzip}
} elseif {[llength [info commands ::zipfs::mkzip]]} {
    set mkzip ::zipfs::mkzip
} else {exit 3}

if {[catch {
    if {[llength $argv] != 2} {error "usage: zip-lambda.tcl ARCHIVE STAGE"}
    lassign $argv archive stage
    {*}$mkzip $archive $stage $stage
} message]} {
    puts stderr $message
    exit 1
}
