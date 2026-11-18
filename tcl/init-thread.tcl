#
# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.
#

package require twebserver
source [file join [file dirname [info script]] config.tcl]
source [file join [file dirname [info script]] site.tcl]
source [file join [file dirname [info script]] telemetry.tcl]
set settings [::twebserver::get_config_dict]
# Each worker owns one connection for telemetry, search and content, as in Lambda.
::telemetry::connect [dict get $settings content_database] -secret_config [dict get $::site_bootstrap_secrets postgres]
dict set settings content_connection $::telemetry::connection
try {
    ::site::init_worker $settings -secret_config $::site_bootstrap_secrets
} on error {message options} {
    ::telemetry::close
    return -options $options $message
} finally {
    unset settings ::site_bootstrap_secrets
}
interp alias {} process_conn {} ::site::process_conn
