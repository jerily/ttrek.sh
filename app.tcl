# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2024 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.

package require twebserver
package require thread
package require tconfig::decrypt

set dir [file dirname [info script]]

set config_enc_filepath [file join $dir etc config.enc]
set config_ini_filepath [file join $dir etc config.ini]
if { [file exists $config_enc_filepath] } {
    set config [::tconfig::load_config $config_enc_filepath]
} elseif { [file exists $config_ini_filepath] } {
    set config [::tconfig::read_config $config_ini_filepath]
} else {
    puts "No configuration file found"
    exit 1
}

# tratelimit

set tratelimit_config {
    store {
        valkeystore {
            host "localhost"
            port 6379
            password "foobared"
        }
    }
    global_limits {
        by_ip {
            window_millis 10000
            limit 10
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
                limit 10
            }
        }
        get_stats {
            by_ip {
                window_millis 10000
                limit 5
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

dict set tratelimit_config store valkeystore [dict create \
    host [dict get $config redis host] \
    port [dict get $config redis port]]



# Create telemetry thread
set telemetry_thread_id [thread::create thread::wait]

# use threads and gzip compression
set config_dict [dict create \
    rootdir [file dirname [info script]] \
    gzip on \
    gzip_types [list text/plain application/json] \
    gzip_min_length 8192 \
    conn_timeout_millis 10000 \
    telemetry_thread_id $telemetry_thread_id \
    tratelimit $tratelimit_config]

# create the server
set dir [file dirname [info script]]

# Initialize the telemetry thread
if { ![file exists [file join $dir data]] } {
    file mkdir [file join $dir data]
}
thread::send $telemetry_thread_id [list source [file normalize [file join $dir tcl telemetry.tcl]]]
thread::send $telemetry_thread_id [list ::telemetry::init \
    -file [file normalize [file join $dir data telemetry.sqlite3]]]

set init_script "source [file normalize [file join $dir tcl init-thread.tcl]]"
set server_handle [::twebserver::create_server -with_router $config_dict process_conn $init_script]

file mkdir [file join $dir certs]
set ttrek_sh_key [file normalize [file join $dir "certs/key.pem"]]
set ttrek_sh_cert [file normalize [file join $dir "certs/cert.pem"]]

writeFile $ttrek_sh_key [binary decode base64 [dict get $config ssl key]]
writeFile $ttrek_sh_cert [binary decode base64 [dict get $config ssl certificate]]

::twebserver::add_context $server_handle ttrek.sh $ttrek_sh_key $ttrek_sh_cert
::twebserver::add_context $server_handle www.ttrek.sh $ttrek_sh_key $ttrek_sh_cert

file delete -force $ttrek_sh_key
file delete -force $ttrek_sh_cert

# listen for an HTTPS connection on port 4433
::twebserver::listen_server -num_threads 4 $server_handle 4433

# listen for an HTTP connection on port 8080
::twebserver::listen_server -num_threads 2 -http $server_handle 8080

# print that the server is running
puts "server is running. go to http://ttrek.sh:8080/ or https://ttrek.sh:4433/"

# wait forever
::twebserver::wait_signal

# destroy the server
::twebserver::destroy_server $server_handle

