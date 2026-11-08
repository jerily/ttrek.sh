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
try {
    set ::env(ENV) PROD
    set config [::tconfig::load_config [lindex $argv 1]]
    set settings [::app_config::telemetry $config $root]
    ::telemetry::init $settings
    ::telemetry::close
    set db [::telemetry_maintenance::connect $settings]
    set counts [::telemetry_maintenance::restore $db [lindex $argv 0]]
    puts "Telemetry restored: $counts"
} on error {message options} {
    # Driver errors may include the target connection settings or row data.
    puts stderr "Telemetry restore failed; verify the backup and an empty, reachable target database."
    exit 1
} finally {if {$db ne {}} {catch {$db close}}}
