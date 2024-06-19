# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2024 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.

package require twebserver

set init_script {
    package require twebserver
    package require thtml
    package require tjson

    ::thtml::init [dict create \
        cache 0 \
        rootdir [file dirname [info script]]]

    set router [::twebserver::create_router]

    ::twebserver::add_route -strict $router GET / get_index_page_handler
    ::twebserver::add_route $router -strict GET /package/:package_name get_package_page_handler
    ::twebserver::add_route $router -strict GET /registry/:package_name/:package_version get_package_spec_handler
    ::twebserver::add_route $router -strict GET /registry/:package_name get_package_versions_handler
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

    proc get_package_versions {dir package_name} {
        set versions [list]
        foreach path [glob -nocomplain -type d [file join $dir registry $package_name/*]] {
            lappend versions [file tail $path]
        }
        return [lsort -command compare_versions -decreasing $versions]
    }

    proc get_package_version_dependencies {dir package_name version} {
        set deps [list]
        set spec_path [file join $dir registry $package_name $version ttrek.json]
        if {![file exists $spec_path]} {
            error "spec file not found"
        }

        set fp [open $spec_path]
        set data [read $fp]
        close $fp

        ::tjson::parse $data spec_handle
        set deps_handle [::tjson::get_object_item $spec_handle dependencies]
        set deps [::tjson::to_simple $deps_handle]
        return $deps
    }

    proc get_latest_version {dir package_name} {
        set versions [get_package_versions $dir $package_name]
        set latest_version [lindex $versions 0]
        return $latest_version
    }

    proc get_package_versions_handler {ctx req} {
        set dir [::twebserver::get_rootdir]
        set package_name [::twebserver::get_path_param $req package_name]
        set versions_typed [list]
        foreach version [get_package_versions $dir $package_name] {
            set deps [get_package_version_dependencies $dir $package_name $version]
            set deps_typed [list]
            foreach {dep_name dep_version} $deps {
                lappend deps_typed $dep_name [list S $dep_version]
            }
            lappend versions_typed $version [list M $deps_typed]
        }
        return [::twebserver::build_response 200 application/json \
            [::tjson::typed_to_json [list M $versions_typed]]]
    }

    proc get_package_spec_handler {ctx req} {
        set package_name [::twebserver::get_path_param $req package_name]
        set package_version [::twebserver::get_path_param $req package_version]
        set dir [::twebserver::get_rootdir]

        if { $package_version eq "latest" } {
            set package_version [get_latest_version $dir $package_name]
            if { $package_version eq {} } {
                return [::twebserver::build_response 404 text/plain "not found"]
            }
        }

        set spec_path [file join $dir registry $package_name $package_version ttrek.json]
        set install_script_path [file join $dir registry $package_name $package_version install.sh]
        if {![file exists $spec_path] || ![file exists $install_script_path]} {
            return [::twebserver::build_response 404 text/plain "not found"]
        }

        set fp [open $spec_path]
        set data [read $fp]
        close $fp

        ::tjson::parse $data spec_handle
        set deps_handle [::tjson::get_object_item $spec_handle dependencies]
        set deps_typed [::tjson::to_typed $deps_handle]

        set fp [open $install_script_path]
        set data [read $fp]
        close $fp

        set base64_install_script [::twebserver::base64_encode $data]

        set patches_typed [list]
        foreach patch_path [glob -nocomplain -type f [file join $dir registry $package_name $package_version *.diff]] {
            set fp [open $patch_path]
            set data [read $fp]
            close $fp
            lappend patches_typed [file tail $patch_path] [list S [::twebserver::base64_encode $data]]
        }
        ::tjson::create \
            [list M \
                [list \
                    version [list S $package_version] \
                    dependencies $deps_typed \
                    install_script [list S $base64_install_script]]] \
            result_handle

        if { $patches_typed ne {} } {
            ::tjson::add_item_to_object $result_handle patches [list M $patches_typed]
        }

        set res [::twebserver::build_response 200 application/json [::tjson::to_json $result_handle]]
        return $res
    }

    proc compare_versions {a b} {
        set a_parts [split $a .]
        set b_parts [split $b .]
        set len [expr {[llength $a_parts] < [llength $b_parts] ? [llength $a_parts] : [llength $b_parts]}]
        for {set i 0} {$i < $len} {incr i} {
            set a_part [lindex $a_parts $i]
            set b_part [lindex $b_parts $i]
            if {$a_part < $b_part} {
                return -1
            } elseif {$a_part > $b_part} {
                return 1
            }
        }
        return 0
    }

    proc get_package_page_handler {ctx req} {
        set package_name [::twebserver::get_path_param $req package_name]
        set versions [list]
        foreach path [glob -nocomplain -type d [file join [::twebserver::get_rootdir] registry $package_name/*]] {
            lappend versions [file tail $path]
        }
        set data [dict merge $req [list package_name $package_name versions [lsort -command compare_versions -decreasing $versions]]]
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

