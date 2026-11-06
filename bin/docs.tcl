package require Tcl 9.1
set root [file dirname [file dirname [file normalize [info script]]]]
lappend auto_path [file join $::env(TTREK_SITE_PREFIX) lib]
package require web-wiki 0.1.0

if {[llength $argv] > 2 || [lindex $argv 0] ni {init sync}} {
    puts stderr {Usage: docs.tcl init|sync ?DATABASE?}
    exit 1
}
set database [file join $root data docs.sqlite3]
if {[llength $argv] == 2} {set database [file normalize [lindex $argv 1]]}
if {[lindex $argv 0] eq "sync" && ![file isfile $database]} {error "initialize documentation first"}
file mkdir [file dirname $database]
set connection [::tpersist::db_connect -database $database -autobegin 0 -timeout 5000]
try {
    if {[lindex $argv 0] eq "init"} {::web::wiki::initdb $connection}
    set store [::web::wiki::create -connection $connection -domain ttrek.sh -title Documentation]
    puts [::web::wiki::sync $store [file join $root content docs]]
} finally {::tpersist::db_disconnect $connection}
