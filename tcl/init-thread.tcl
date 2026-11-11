package require twebserver
source [file join [file dirname [info script]] config.tcl]
source [file join [file dirname [info script]] site.tcl]
::site::init_worker [::twebserver::get_config_dict]
interp alias {} process_conn {} ::site::process_conn
