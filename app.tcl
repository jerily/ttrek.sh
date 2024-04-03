# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2023 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.

package require twebserver

set init_script {
    package require twebserver
    package require thtml

    ::thtml::init [dict create \
        cache 0 \
        rootdir [file join [file dirname [info script]] www]]

    set router [::twebserver::create_router]

    ::twebserver::add_route -strict $router GET / get_index_page_handler
    ::twebserver::add_route $router -strict GET /package/:package_name get_package_page_handler
    ::twebserver::add_route $router -strict GET /registry/:package_name/:package_version get_package_spec_handler
    ::twebserver::add_route $router -strict GET /registry/:package_name/:package_version/install.sh get_package_script_handler
    ::twebserver::add_route -strict $router GET /logo get_logo_handler
    ::twebserver::add_route $router GET "*" get_catchall_handler

    # make sure that the router will be called when the server receives a connection
    interp alias {} process_conn {} $router

    proc get_index_page_handler {ctx req} {
        set package_names [list]
        foreach path [glob -nocomplain -type d [file join [::twebserver::get_rootdir] registry/*]] {
            lappend package_names [file tail $path]
        }
        set data [dict merge $req [list title "Packages" package_names [lsort $package_names]]]
        set html [::thtml::renderfile index.thtml $data]
        set res [::twebserver::build_response 200 text/html $html]
        return $res
    }

    proc get_logo_handler {ctx req} {
        set server_handle [dict get $ctx server]
        set dir [::thtml::get_rootdir]
        set filepath [file join $dir plume.png]
        set res [::twebserver::build_response -return_file 200 image/png $filepath]
        return $res
    }

    proc get_package_spec_handler {ctx req} {
        set package_name [::twebserver::get_path_param $req package_name]
        set package_version [::twebserver::get_path_param $req package_version]
        set dir [::twebserver::get_rootdir]
        set filepath [file join $dir registry $package_name $package_version ttrek.json]
        if {![file exists $filepath]} {
            set res [::twebserver::build_response 404 text/plain "not found"]
            return $res
        }
        set res [::twebserver::build_response -return_file 200 application/json $filepath]
        return $res
    }

    proc get_package_script_handler {ctx req} {
        set package_name [::twebserver::get_path_param $req package_name]
        set package_version [::twebserver::get_path_param $req package_version]
        set dir [::twebserver::get_rootdir]
        set filepath [file join $dir registry $package_name $package_version install.sh]
        if {![file exists $filepath]} {
            set res [::twebserver::build_response 404 text/plain "not found"]
            return $res
        }
        set res [::twebserver::build_response -return_file 200 text/plain $filepath]
        return $res
    }

    proc get_package_page_handler {ctx req} {
        set package_name [::twebserver::get_path_param $req package_name]
        set versions [list]
        foreach path [glob -nocomplain -type d [file join [::twebserver::get_rootdir] registry $package_name/*]] {
            lappend versions [file tail $path]
        }
        set data [dict merge $req [list package_name $package_name versions [lsort -decreasing $versions]]]
        set html [::thtml::renderfile package.thtml $data]
        set res [::twebserver::build_response 200 text/html $html]
        return $res
    }

    proc get_catchall_handler {ctx req} {
        set res [::twebserver::build_response 404 text/plain "not found"]
        return $res
    }

}

# use threads and gzip compression
set config_dict [dict create \
    num_threads 10 \
    rootdir [file dirname [info script]] \
    gzip on \
    gzip_types [list text/plain application/json] \
    gzip_min_length 20]

# create the server
set server_handle [::twebserver::create_server $config_dict process_conn $init_script]

# listen for an HTTP connection on port 8080
::twebserver::listen_server -http $server_handle 8080

# print that the server is running
puts "server is running. go to http://localhost:8080/"

# wait forever
vwait forever

# destroy the server
::twebserver::destroy_server $server_handle

