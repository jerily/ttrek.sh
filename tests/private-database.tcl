# Adapt raw test-fixture connection dictionaries to the explicit private API.
namespace eval ::test_private_db {}
proc ::test_private_db::separate {settings} {
    ::private_config::partition [dict create content_database $settings]
}
proc ::test_private_db::connect {settings} {
    set parts [separate $settings]
    ::telemetry::connect [dict get $parts config content_database] -secret_config [dict get $parts secret_config postgres]
}
proc ::test_private_db::init_local {settings {directories {}}} {
    set parts [separate $settings]
    ::telemetry::init_local [dict get $parts config content_database] $directories -secret_config [dict get $parts secret_config postgres]
}
