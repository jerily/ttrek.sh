# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2024 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.

package require twebserver

# use threads and gzip compression
set config_dict [dict create \
    num_threads 10 \
    rootdir [file dirname [info script]] \
    gzip on \
    gzip_types [list text/plain application/json] \
    gzip_min_length 20]

# create the server
set dir [file dirname [info script]]

set init_script "source [file normalize [file join $dir tcl init-thread.tcl]]"
set server_handle [::twebserver::create_server -with_router $config_dict process_conn $init_script]

set ttrek_sh_key [file normalize [file join $dir "certs/key.pem"]]
set ttrek_sh_cert [file normalize [file join $dir "certs/cert.pem"]]
::twebserver::add_context $server_handle ttrek.sh $ttrek_sh_key $ttrek_sh_cert

# listen for an HTTPS connection on port 4433
::twebserver::listen_server -num_threads 8 $server_handle 4433

# listen for an HTTP connection on port 8080
::twebserver::listen_server -http $server_handle 8080

# print that the server is running
puts "server is running. go to http://ttrek.sh:8080/ or https://ttrek.sh:4433/"

# wait forever
vwait forever

# destroy the server
::twebserver::destroy_server $server_handle

