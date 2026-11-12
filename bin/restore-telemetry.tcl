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
    ::telemetry::connect $settings
    ::telemetry::initdb
    ::telemetry::close
    set db [::telemetry_maintenance::connect $settings]
    set counts [::telemetry_maintenance::restore $db [lindex $argv 0]]
    set restored true
    ::telemetry::connect $settings
    try {::telemetry::publish_search_snapshot} finally {::telemetry::close}
    puts "Telemetry restored: $counts"
} on error {message options} {
    # Driver errors may include the target connection settings or row data.
    if {$restored} {
        puts stderr "Telemetry was restored, but search publication failed. Run task_publish_search on the target before enabling search."
    } else {
        puts stderr "Telemetry restore failed; verify the backup and an empty, reachable target database."
    }
    exit 1
} finally {if {$db ne {}} {catch {$db close}}}
