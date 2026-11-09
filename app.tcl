# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2024 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.

if {$argv ne {}} {error "Usage: app.tcl"}

package require Tcl 9.1
package require twebserver
package require thread
package require tconfig::decrypt

set dir [file dirname [info script]]

source [file join $dir tcl config.tcl]
set config [::app_config::load $dir]

# Shared TLS connection settings for both middleware stores.
set valkey_config [::app_config::valkey $config]
set releases_config [::app_config::releases $config]

# tratelimit

set tratelimit_config {
    global_limits {
        by_ip {
            window_millis 10000
            limit 1000
        }
        by_session {
            window_millis 60000
            limit 5
        }
    }
    route_limits {
        get_index {
            by_ip {
                window_millis 10000
                limit 100
            }
        }
        get_catchall {
            by_ip {
                window_millis 10000
                limit 15
            }
        }
    }
}

dict set tratelimit_config store valkeystore $valkey_config

set treqmon_config [dict create store [::app_config::monitor_store $config]]



# Create telemetry thread
set telemetry_thread_id [thread::create thread::wait]

# Compression is shared with Lambda in ::responses::prepare.
set config_dict [dict create \
    rootdir [file dirname [info script]] \
    registry_dir [dict get $config registry directory] \
    releases $releases_config \
    request_monitor [::app_config::request_monitor $config] \
    gzip off \
    conn_timeout_millis 10000 \
    telemetry_thread_id $telemetry_thread_id \
    tratelimit $tratelimit_config \
    treqmon $treqmon_config]

# create the server
set dir [file dirname [info script]]

# Initialize one database connection owned by the telemetry thread.
thread::send $telemetry_thread_id [list source [file normalize [file join $dir tcl telemetry.tcl]]]
# Keep credentials out of a failed thread script's error trace.
thread::send $telemetry_thread_id [list set ::telemetry_settings \
    [::app_config::telemetry $config [file normalize $dir]]]
thread::send $telemetry_thread_id {
    try {::telemetry::init $::telemetry_settings} finally {unset ::telemetry_settings}
}

set init_script "source [file normalize [file join $dir tcl init-thread.tcl]]"
set server_handle [::twebserver::create_server $config_dict process_conn $init_script]

file mkdir [file join $dir certs]
set ttrek_sh_key [file normalize [file join $dir "certs/key.pem"]]
set ttrek_sh_cert [file normalize [file join $dir "certs/cert.pem"]]

writeFile $ttrek_sh_key [binary decode base64 [dict get $config ssl key]]
writeFile $ttrek_sh_cert [binary decode base64 [dict get $config ssl certificate]]

::twebserver::add_context $server_handle ttrek.sh $ttrek_sh_key $ttrek_sh_cert
::twebserver::add_context $server_handle www.ttrek.sh $ttrek_sh_key $ttrek_sh_cert
if {[::app_config::mode] eq "LOCAL"} {
    ::twebserver::add_context $server_handle localhost $ttrek_sh_key $ttrek_sh_cert
}

file delete -force $ttrek_sh_key
file delete -force $ttrek_sh_cert

# listen for an HTTPS connection on port 4433
::twebserver::listen_server -num_threads 4 $server_handle 4433

# listen for an HTTP connection on port 8080
::twebserver::listen_server -num_threads 2 -http $server_handle 8080

# print that the server is running
puts "server is running. go to http://localhost:8080/ or https://localhost:4433/"

# wait forever
::twebserver::wait_signal

# destroy the server
::twebserver::destroy_server $server_handle

