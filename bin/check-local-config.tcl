# Validate before the launcher starts any services. No connections or writes.
set root [file dirname [file dirname [file normalize [info script]]]]
source [file join $root tcl config.tcl]
set ::env(ENV) LOCAL
::app_config::monitor_store [::app_config::lambda_config $root]
