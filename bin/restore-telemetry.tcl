#
# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.
#

# Run using the installed application Tcl runtime. The target configuration is
# explicit: never accidentally restore into the website's production database.
if {[llength $argv] != 2} {
    puts stderr "Usage: restore-telemetry.tcl BACKUP.jsonl.gz TARGET-CONFIG.ini"
    exit 2
}
set root [file dirname [file dirname [file normalize [info script]]]]
package require tconfig::decrypt
package require tjson
source [file join $root tcl config.tcl]
source [file join $root tcl telemetry.tcl]
source [file join $root tcl telemetry-maintenance.tcl]
set db {}
set restored false
try {
    set ::env(ENV) PROD
    set config [::tconfig::load_config [lindex $argv 1]]
    set settings [::app_config::telemetry $config $root]
    set channel [open [lindex $argv 0] rb]
    try {
        zlib push gunzip $channel
        fconfigure $channel -encoding utf-8 -translation lf
        set format [dict get [::tjson::json_to_simple [gets $channel]] format]
    } finally {close $channel}
    if {$format eq "tpersist"} {
        package require tpersist 0.1.5
        set options {-autobegin false}
        dict for {key value} $settings {lappend options -$key $value}
        set connection [::tpersist::db_connect {*}$options]
        try {
            set counts [::tpersist::db_import_jsonl $connection [lindex $argv 0]]
        } finally {::tpersist::db_disconnect $connection}
        puts "Application tables restored: $counts"
    } elseif {$format eq "ttrek-telemetry"} {
        # Historical backups contained only telemetry and used package schemas.
        ::telemetry::connect $settings
        ::telemetry::initdb
        ::telemetry::close
        set db [::telemetry_maintenance::connect $settings]
        set counts [::telemetry_maintenance::restore $db [lindex $argv 0]]
        set restored true
        ::telemetry::connect $settings
        try {::telemetry::publish_search_snapshot} finally {::telemetry::close}
        puts "Telemetry restored: $counts"
    } else {error "Unsupported backup format"}
} on error {message options} {
    # Driver errors may include the target connection settings or row data.
    if {$restored} {
        puts stderr "Telemetry was restored, but search publication failed. Run task_publish_search on the target before enabling search."
    } else {
        puts stderr "Database restore failed; verify the backup and an empty, reachable target database."
    }
    exit 1
} finally {if {$db ne {}} {catch {$db close}}}
