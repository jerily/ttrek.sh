package require twebserver
source [file join [file dirname [info script]] config.tcl]
source [file join [file dirname [info script]] site.tcl]
source [file join [file dirname [info script]] telemetry.tcl]
set settings [::twebserver::get_config_dict]
# Each worker owns one connection for telemetry, search and content, as in Lambda.
::telemetry::connect [dict get $settings content_database]
dict set settings content_connection $::telemetry::connection
try {
    ::site::init_worker $settings
} on error {message options} {
    ::telemetry::close
    return -options $options $message
} finally {
    unset settings
}
interp alias {} process_conn {} ::site::process_conn
