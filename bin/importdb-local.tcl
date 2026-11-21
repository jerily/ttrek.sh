# Copyright Jerily LTD. All Rights Reserved.
# SPDX-License-Identifier: MIT.

namespace eval ::local_import {}

# Use the same SQLite destination as the local Lambda runtime. Schema comes
# exclusively from the backup; package provisioning is intentionally unnecessary.
proc ::local_import::main {root arguments} {
    if {![llength $arguments] || "--help" in $arguments || "-h" in $arguments} {
        return "Usage: importdb-local.sh BACKUP.jsonl\[.gz\] ?--data-dir DIRECTORY? ?--tables {table ...}?"
    }
    set path [file normalize [lindex $arguments 0]]
    set dataDirectory /tmp/ttrek-local
    if {[info exists ::env(TTREK_LOCAL_RUNTIME_DATA)]} {set dataDirectory $::env(TTREK_LOCAL_RUNTIME_DATA)}
    set options [lrange $arguments 1 end]
    if {[llength $options] % 2} {error "Expected --data-dir DIRECTORY or --tables LIST"}
    set importOptions {}
    foreach {name value} $options {
        switch -- $name {
            --data-dir {set dataDirectory $value}
            --tables {lappend importOptions -tables $value}
            default {error "Unknown option: $name"}
        }
    }
    if {![file isfile $path]} {error "Backup file does not exist"}
    package require tpersist 0.1.7
    source [file join $root tcl config.tcl]
    # This command never loads production configuration, regardless of ENV.
    set ::env(ENV) LOCAL
    set settings [::app_config::telemetry {} $root $dataDirectory]
    set connectionOptions {-autobegin false}
    dict for {key value} $settings {lappend connectionOptions -$key $value}
    set connection [::tpersist::db_connect {*}$connectionOptions]
    try {
        set counts [::tpersist::db_import_jsonl $connection $path {*}$importOptions]
    } finally {::tpersist::db_disconnect $connection}
    return "Imported into [dict get $settings database]: $counts"
}

if {[file normalize [info script]] eq [file normalize $argv0]} {
    set root [file dirname [file dirname [file normalize [info script]]]]
    if {[catch {::local_import::main $root $argv} result options]} {
        # Driver diagnostics can include private backup contents.
        puts stderr "Local import failed. Verify the backup, table selection, and an empty compatible destination."
        exit 1
    }
    puts $result
}
