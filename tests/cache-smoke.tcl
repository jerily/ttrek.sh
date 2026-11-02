package require tconfig::decrypt
package require valkey 1.0.1
lassign $argv root action
source [file join $root tcl config.tcl]
set config [::app_config::valkey [::app_config::load $root]]
set client [valkey -ssl -host [dict get $config host] -port [dict get $config port] \
    -ssl_ca_file [dict get $config ssl_ca_file] -username [dict get $config username] \
    -password [dict get $config password] -timeout 3000]
try {
    if {$action eq "disconnect"} {
        $client raw CLIENT KILL TYPE normal SKIPME yes
    } else {
        if {[$client LLEN history_events] == 0} {error "Request events are missing from Valkey"}
        if {![llength [$client KEYS __RL__/*]]} {error "Rate-limit counters are missing from Valkey"}
        puts "Valkey contains request history and rate-limit counters"
    }
} finally {
    $client destroy
}
