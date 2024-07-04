# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2024 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.

package require twebserver
package require thtml
package require tjson
package require thread

::thtml::init [dict create \
    cache 0 \
    rootdir [::twebserver::get_rootdir]]

set router [::twebserver::create_router]

::twebserver::add_route -strict $router GET / get_index_page_handler
::twebserver::add_route -strict $router GET /packages get_packages_page_handler
::twebserver::add_route -strict $router GET "/dist/{:arch}/ttrek{:ext}?" get_dist_handler
::twebserver::add_route $router -strict GET /package/:package_name get_package_page_handler
::twebserver::add_route $router -strict GET /package/:package_name/:package_version get_package_version_page_handler
::twebserver::add_route $router -strict GET /registry/:package_name/:package_version/:os/:machine get_package_spec_handler
::twebserver::add_route $router -strict GET /registry/:package_name get_package_versions_handler
::twebserver::add_route $router -strict POST /telemetry/register/:environment_id post_telemetry_register_handler
::twebserver::add_route $router -strict POST /telemetry/collect/:package_name/:package_version post_telemetry_collect_handler
::twebserver::add_route -strict $router GET /logo get_logo_handler
::twebserver::add_route $router GET "*" get_catchall_handler

# make sure that the router will be called when the server receives a connection
interp alias {} process_conn {} $router

proc telemetry_event { event_type args } {
    thread::send -async [dict get [::twebserver::get_config_dict] telemetry_thread_id] \
        [list ::telemetry::event $event_type {*}$args]
}

proc telemetry_sql { sql args } {
    if { [llength $args] == 1 } {
        set args [lindex $args 0]
    }
    # Don't throw errors in case of any telemetry db issues so as not to break
    # HTTP queries. Return an empty response and log the error to stdout.
    if { [catch {
        thread::send [dict get [::twebserver::get_config_dict] telemetry_thread_id] \
            [list ::telemetry::sql $sql $args]
    } result] } {
        puts "Error while accessing telemetry db: $result\nSQL: $sql\nVariables: $args"
        set result ""
    }
    return $result
}

proc telemetry_event_common { event_type args } {
    upvar 1 req req
    if { ![dict exists [dict get $req headers] ttrek-environment-id] } {
        puts "WARNING: telemetry_event_common: no ttrek-environment-id"
        return
    }
    set environment_id [dict get $req headers ttrek-environment-id]
    if { ![validate_environment_id $environment_id] } {
        return
    }
    telemetry_event $event_type -env $environment_id {*}$args
}

proc post_telemetry_collect_handler {ctx req} {
    set package_name [::twebserver::get_path_param $req package_name]
    set package_version [::twebserver::get_path_param $req package_version]

    set data [dict get $req body]
    if { [catch {
        ::tjson::parse $data data_handle
    } err] } {
        return -code error "post_package_handler: ERROR while parsing json\
            data for \"$package_name\" version \"$package_version\": $err"
    }

    if { [catch {
        set action [::tjson::to_simple [::tjson::get_object_item \
            $data_handle action]]
    } err] } {
        return -code error "post_package_handler: ERROR: no action field in\
            json data for \"$package_name\" version \"$package_version\": $err"
    }
    if { $action ne "install" } {
        return -code error "post_package_handler: ERROR: unsupported action\
            \"$action\" in\ json data for \"$package_name\" version\
            \"$package_version\""
    }

    if { [catch {
        set outcome [::tjson::to_simple [::tjson::get_object_item \
            $data_handle outcome]]
    } err] } {
        return -code error "post_package_handler: ERROR: no outcome field\
            for install action in json data for \"$package_name\" version\
            \"$package_version\": $err"
    }
    if { $outcome ni {success failure} } {
        return -code error "post_package_handler: ERROR: unsupported outcome\
            \"$outcome\" for install action in json data for \"$package_name\"\
            version \"$package_version\""
    }

    set outcome [expr { $outcome eq "success" ? 1 : 0 }]

    if { [catch {
        set is_toplevel [::tjson::to_simple [::tjson::get_object_item \
            $data_handle is_toplevel]]
    } err] } {
        return -code error "post_package_handler: ERROR: no is_toplevel field\
            for install action in json data for \"$package_name\" version\
            \"$package_version\": $err"
    }
    if { ![string is boolean -strict $is_toplevel] } {
        return -code error "post_package_handler: ERROR: unsupported\
            is_toplevel \"$is_toplevel\" for install action in json data for\
            \"$package_name\" version \"$package_version\""
    }

    set is_toplevel [expr { [string is true -strict $is_toplevel] ? 1 : 0 }]

    if { [catch {
        set os [::tjson::to_simple [::tjson::get_object_item \
            $data_handle os]]
    } err] } {
        return -code error "post_package_handler: ERROR: no os field\
            for install action in json data for \"$package_name\" version\
            \"$package_version\": $err"
    }

    if { [catch {
        set arch [::tjson::to_simple [::tjson::get_object_item \
            $data_handle arch]]
    } err] } {
        return -code error "post_package_handler: ERROR: no arch field\
            for install action in json data for \"$package_name\" version\
            \"$package_version\": $err"
    }

    telemetry_event_common req_pkg_install_event -pkg_name $package_name \
        -pkg_version $package_version -install_outcome $outcome \
        -install_is_toplevel $is_toplevel -os $os -arch $arch

    return [::twebserver::build_response 200 text/plain "ok"]
}

proc get_dist_handler {ctx req} {
    set arch [::twebserver::get_path_param $req arch]
    telemetry_event_common req_dist_get -os linux -arch $arch
    set ext [::twebserver::get_path_param $req ext]
    # hardcode for alpine
    # set arch "alpine"
    set dir [::twebserver::get_rootdir]
    set filename "ttrek-$arch$ext"
    set filepath [file normalize [file join $dir dist $filename]]
    return [::twebserver::build_response -return_file 200 application/octet-stream $filepath]
}

proc get_index_page_handler {ctx req} {
    set host [::twebserver::get_header $req host]
    if { $host ne {} } {
        lassign [split $host {:}] hostname port
        if { $hostname eq {get.ttrek.sh} } {
            return [::twebserver::build_response -return_file 200 application/octet-stream [::twebserver::get_rootdir]/public/ttrek-init]
        }
    }
    set data [dict merge $req [list title "Install ttrek"]]
    set html [::thtml::renderfile index.thtml $data]
    set res [::twebserver::build_response 200 text/html $html]
    return $res
}

proc get_packages_page_handler {ctx req} {
    set package_names [list]
    foreach path [glob -nocomplain -type d [file join [::twebserver::get_rootdir] registry/*]] {
        lappend package_names [file tail $path]
    }
    set data [dict merge $req [list title "Packages" package_names [lsort $package_names]]]
    set html [::thtml::renderfile packages.thtml $data]
    set res [::twebserver::build_response 200 text/html $html]
    return $res
}

proc get_logo_handler {ctx req} {
    telemetry_event_common req_logo_get
    set dir [::thtml::get_rootdir]
    set filepath [file join $dir www plume.png]
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

    if { [catch {
        ::tjson::parse $data spec_handle
    } err] } {
        return -code error "Error while parsing json file for \"$package_name\"\
            version \"$version\": $err"
    }
    set deps_handle [::tjson::get_object_item $spec_handle dependencies]
    set deps [::tjson::to_simple $deps_handle]
    return $deps
}

proc get_latest_version {dir package_name} {
    set versions [get_package_versions $dir $package_name]
    set latest_version [lindex $versions 0]
    return $latest_version
}

proc validate_environment_id {environment_id} {
    # Check that environment_id consists of 32 characters in
    # the range [1-9a-f] (hexadecimal characters)
    set valid [regexp -nocase {^[0-9a-f]{64}$} $environment_id]
    if { !$valid } {
        puts "WARNING: invalid environment_id \"$environment_id\""
    }
    return $valid
}

proc post_telemetry_register_handler {ctx req} {
    set environment_id [::twebserver::get_path_param $req environment_id]
    if { [validate_environment_id $environment_id] } {
        set body [dict get $req body]
        set size [string length $body]
        # Prohibit body size larger than 65535 bytes to avoid database denial of service
        # or empty data.
        if { $size > 0xffff || !$size } {
            puts "WARNING: register_environment: blocked body size [string length $body]"
        } else {
            telemetry_event register_environment -env $environment_id -description $body
        }
    }
    return [::twebserver::build_response 200 text/plain "ok"]
}

proc get_package_versions_handler {ctx req} {
    set dir [::twebserver::get_rootdir]
    set package_name [::twebserver::get_path_param $req package_name]
    telemetry_event_common req_reg_get_pkg -pkg_name $package_name
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

proc shell_quote {string} {
    set string [string map [list {'} {'"'"'}] $string]
    return "'$string'"
}
proc shell_quote_double {string} {
    set string [string map [list "\"" "\\\"" "\\" "\\\\"] $string]
    return "\"$string\""
}

proc gen_package_spec_command {opts} {
    set result [list]
    if { ![dict exists $opts cmd] } {
        return $result
    }
    switch -exact -- [dict get $opts cmd] {
        "download" {
            lappend result "LD_LIBRARY_PATH= curl --fail --silent --show-error -L\
                -o [shell_quote_double {$ARCHIVE_FILE}]\
                --output-dir [shell_quote_double {$DOWNLOAD_DIR}]\
                [dict get $opts url]"
            if { false && [dict exists $opts sha256] } {
                lappend result "HASH=\"\$(sha256sum --binary [shell_quote_double {$DOWNLOAD_DIR/$ARCHIVE_FILE}]\
                    | awk '{print \$1}')\""
                lappend result "\[ \"\$HASH\" = [shell_quote [dict get $opts sha256]] \]\
                    || { echo \"sha256 doesn't match.\"; exit 1; }"
            }
        }
        "git" {
            set cmd "git -C [shell_quote_double {$SOURCE_DIR}] clone [shell_quote [dict get $opts url]]\
                --depth 1 --single-branch"
            if { [dict exists $opts branch] } {
                append cmd " --branch [shell_quote [dict get $opts branch]]"
            }
            if { [dict exists $opts recurse-submodules] && [string is true -strict [dict get $opts recurse-submodules]] } {
                append cmd " --recurse-submodules"
            }
            if { [dict exists $opts shallow-submodules] && [string is true -strict [dict get $opts shallow-submodules]] } {
                append cmd " --shallow-submodules"
            }
            append cmd " ."
            lappend result $cmd
            lappend result "find [shell_quote_double \$SOURCE_DIR] -name '.git' | xargs rm -rf"
        }
        "unpack" {
            if { ![dict exists $opts format] } {
                dict set opts format tar.gz
            }
            switch -exact -- [dict get $opts format] {
                "zip" {
                    lappend result "unzip [shell_quote_double {$DOWNLOAD_DIR/$ARCHIVE_FILE}]\
                        -d [shell_quote_double {$SOURCE_DIR}]"
                    lappend result "TEMP=\"\$(echo [shell_quote_double {$SOURCE_DIR}]/*)\""
                    # This will not move hidden files from subdirectory to
                    # the build directory. But it shouldn't matter.
                    lappend result "mv [shell_quote_double {$TEMP}]/* [shell_quote_double {$SOURCE_DIR}]"
                    lappend result "rm -rf [shell_quote_double {$TEMP}]"
                }
                default {
                    lappend result "tar -xzf [shell_quote_double {$DOWNLOAD_DIR/$ARCHIVE_FILE}]\
                        --strip-components=1 -C [shell_quote_double {$SOURCE_DIR}]"
                }
            }
        }
        "patch" {
            lappend result "cd [shell_quote_double {$SOURCE_DIR}]"
            set cmd "cat [shell_quote_double "\$PATCH_DIR/patch-\${PACKAGE}-\${VERSION}-[dict get $opts filename]"] |\
                patch"
            if { [dict exists $opts p_num] } {
                append cmd " [shell_quote "-p[dict get $opts p_num]"]"
            }
            append cmd " >[shell_quote_double "\$BUILD_LOG_DIR/patch-[dict get $opts filename].log"] 2>&1"
            lappend result $cmd
        }
        "cd" {
            if { ![dict exists $opts dirname] } {
                set dirname {$BUILD_DIR}
            } else {
                set dirname [dict get $opts dirname]
            }
            lappend result "cd [shell_quote_double $dirname]"
        }
        "autogen" {

            if { ![dict exists $opts options] } {
                set options [list]
            } else {
                set options [dict get $opts options]
            }

            if { [dict exists $opts path] } {
                # todo: make sure the path is under $SOURCE_DIR
                set cmd "[shell_quote_double [dict get $opts path]]"
            } else {
                set cmd {autogen}
            }

            foreach opt $options {
                set option_prefix "--"
                if { [dict exists $opt option_prefix] } {
                    set option_prefix [dict get $opt option_prefix]
                }
                if { [dict exists $opt name] } {
                    if { [dict exists $opt value] } {
                        append cmd " \\\n    [shell_quote "${option_prefix}[dict get $opt name]"]=[shell_quote_double [dict get $opt value]]"
                    } else {
                        append cmd " \\\n    [shell_quote "${option_prefix}[dict get $opt name]"]"
                    }
                }
            }
            append cmd " >[shell_quote_double {$BUILD_LOG_DIR/configure.log}] 2>&1"
            lappend result $cmd

        }
        "configure" {

            if { ![dict exists $opts options] } {
                set options [list]
            } else {
                set options [dict get $opts options]
            }
            # set default configure options
            foreach { k v } {
                prefix $INSTALL_DIR
            } {
                set found 0
                # Check to see if we already have that option defined in spec
                foreach opt $options {
                    if { [dict exists $opt name] && [dict get $opt name] eq $k } {
                        set found 1
                        break
                    }
                }
                if { !$found } {
                    lappend options [dict create {*}[list name $k value $v]]
                }
            }

            set cmd ""
            if { [dict exists $opts ld_library_path] } {
                set cmd "LD_LIBRARY_PATH=[dict get $opts ld_library_path] "
            }

            if { [dict exists $opts path] } {
                # todo: make sure the path is under $SOURCE_DIR
                append cmd "[shell_quote_double [dict get $opts path]]"
            } else {
                append cmd {$SOURCE_DIR/configure}
            }

            foreach opt $options {
                set option_prefix "--"
                if { [dict exists $opt option_prefix] } {
                    set option_prefix [dict get $opt option_prefix]
                }
                if { [dict exists $opt name] } {
                    if { [dict exists $opt value] } {
                        append cmd " \\\n    [shell_quote "${option_prefix}[dict get $opt name]"]=[shell_quote_double [dict get $opt value]]"
                    } else {
                        append cmd " \\\n    [shell_quote "${option_prefix}[dict get $opt name]"]"
                    }
                }
            }
            append cmd " >[shell_quote_double {$BUILD_LOG_DIR/configure.log}] 2>&1"
            lappend result $cmd

        }
        "cmake_config" {

            if { ![dict exists $opts options] } {
                set options [list]
            } else {
                set options [dict get $opts options]
            }
            # set default cmake options
            foreach { k v } {
                CMAKE_INSTALL_PREFIX $INSTALL_DIR
                CMAKE_PREFIX_PATH    $INSTALL_DIR/
            } {
                set found 0
                # Check to see if we already have that option defined in spec
                foreach opt $options {
                    if { [dict exists $opt name] && [dict get $opt name] eq $k } {
                        set found 1
                        break
                    }
                }
                if { !$found } {
                    lappend options [dict create {*}[list name $k value $v]]
                }
            }

            set cmd "cmake [shell_quote_double {$SOURCE_DIR}]"
            foreach opt $options {
                if { [dict exists $opt name] } {
                    if { [dict exists $opt value] } {
                        append cmd " \\\n    [shell_quote "-D[dict get $opt name]"]=[shell_quote_double [dict get $opt value]]"
                    } else {
                        append cmd " \\\n    [shell_quote_double [dict get $opt name]]"
                    }
                }
            }
            append cmd " >[shell_quote_double {$BUILD_LOG_DIR/configure.log}] 2>&1"
            lappend result $cmd

        }
        "make" {
            set cmd "make"
            if { [dict exists $opts options] } {
                foreach opt [dict get $opts options] {
                    if { [dict exists $opt name] } {
                        if { [dict exists $opt value] } {
                            append cmd " \\\n    [shell_quote [dict get $opt name]]=[shell_quote_double [dict get $opt value]]"
                        } else {
                            append cmd " \\\n    [shell_quote_double [dict get $opt name]]"
                        }
                    }
                }
            }
            append cmd " >[shell_quote_double {$BUILD_LOG_DIR/build.log}] 2>&1"
            lappend result $cmd
        }
        "cmake_make" {
            set cmd "cmake --build [shell_quote_double {$BUILD_DIR}]"
            if { [dict exists $opts config] } {
                append cmp " --config=[shell_quote [dict get $opts config]]"
            }
            append cmd " >[shell_quote_double {$BUILD_LOG_DIR/build.log}] 2>&1"
            lappend result $cmd
        }
        "make_install" {
            set cmd ""
            if { [dict exists $opts ld_library_path] } {
                set cmd "LD_LIBRARY_PATH=[dict get $opts ld_library_path] "
            }
            append cmd "make install"
            if { [dict exists $opts options] } {
                foreach opt [dict get $opts options] {
                    if { [dict exists $opt name] } {
                        if { [dict exists $opt value] } {
                            append cmd " \\\n    [shell_quote [dict get $opt name]]=[shell_quote_double [dict get $opt value]]"
                        } else {
                            append cmd " \\\n    [shell_quote_double [dict get $opt name]]"
                        }
                    }
                }
            }
            append cmd " >[shell_quote_double {$BUILD_LOG_DIR/install.log}] 2>&1"
            lappend result $cmd
        }
        "cmake_install" {
            set cmd "cmake --install [shell_quote_double {$BUILD_DIR}]"
            if { [dict exists $opts config] } {
                append cmp " --config=[shell_quote [dict get $opts config]]"
            }
            append cmd " >[shell_quote_double {$BUILD_LOG_DIR/install.log}] 2>&1"
            lappend result $cmd
        }
    }
    return $result
}

proc get_package_spec_handler {ctx req} {
    set package_name [::twebserver::get_path_param $req package_name]
    set package_version [::twebserver::get_path_param $req package_version]
    set os [::twebserver::get_path_param $req os]
    set machine [::twebserver::get_path_param $req machine]

    telemetry_event_common req_reg_get_pkg_spec \
        -pkg_name $package_name -pkg_version $package_version \
        -os $os -arch $machine

    set dir [::twebserver::get_rootdir]

    puts "package_name: $package_name package_version: $package_version os: $os machine: $machine"

    if { $package_version eq "latest" } {
        set package_version [get_latest_version $dir $package_name]
        if { $package_version eq {} } {
            return [::twebserver::build_response 404 text/plain "not found"]
        }
    }

    set spec_path [file join $dir registry $package_name $package_version ttrek.json]
    if {![file exists $spec_path]} {
        return [::twebserver::build_response 404 text/plain "not found"]
    }

    set fp [open $spec_path]
    set data [read $fp]
    close $fp

    if { [catch {
        ::tjson::parse $data spec_handle
    } err] } {
        return -code error "Error while parsing json file for \"$package_name\"\
            version \"$package_version\": $err"
    }
    set deps_handle [::tjson::get_object_item $spec_handle dependencies]
    set deps_typed [::tjson::to_typed $deps_handle]

    set spec_build_handle [::tjson::get_object_item $spec_handle build]
    set platform [string tolower "$os.$machine"]
    if { [::tjson::has_object_item $spec_build_handle $platform] } {
        set spec_build_handle [::tjson::get_object_item $spec_build_handle $platform]
    } elseif { [::tjson::has_object_item $spec_build_handle "default"] } {
        set spec_build_handle [::tjson::get_object_item $spec_build_handle "default"]
    } else {
        return [::twebserver::build_response 404 text/plain "not found"]
    }
    set spec_build [::tjson::to_simple $spec_build_handle]

    set install_script [list]
    foreach cmd $spec_build {
        set cmd_list [gen_package_spec_command $cmd]
        if {![llength $cmd_list]} {
            return -code error "don't know how to render command: $cmd"
        }
        lappend install_script {*}$cmd_list
    }
    # ensure that shell script has trailing new line
    lappend install_script \n
    set install_script [join $install_script \n]

    set base64_install_script [::twebserver::base64_encode $install_script]

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
    telemetry_event_common req_pkg_get -pkg_name $package_name
    set versions [list]
    foreach path [glob -nocomplain -type d [file join [::twebserver::get_rootdir] registry $package_name/*]] {
        lappend versions [file tail $path]
    }

    set stat_platforms [get_package_stats $package_name]

    set data [dict merge $req \
        [list \
            package_name   $package_name \
            versions       [lsort -command compare_versions -decreasing $versions] \
            stat_platforms $stat_platforms \
        ] \
    ]
    set html [::thtml::renderfile package.thtml $data]
    set res [::twebserver::build_response 200 text/html $html]
    return $res
}

proc get_package_version_page_handler {ctx req} {
    set package_name [::twebserver::get_path_param $req package_name]
    set package_version [::twebserver::get_path_param $req package_version]
    telemetry_event_common req_pkg_version_get -pkg_name $package_name -pkg_version $package_version

    set dir [::twebserver::get_rootdir]

    set spec_path [file join $dir registry $package_name $package_version ttrek.json]
    if {![file exists $spec_path]} {
        return [::twebserver::build_response 404 text/plain "not found"]
    }

    set fp [open $spec_path]
    set data [read $fp]
    close $fp

    if { [catch {
        ::tjson::parse $data spec_handle
    } err] } {
        return -code error "Error while parsing json file for \"$package_name\"\
            version \"$package_version\": $err"
    }
    set deps_handle [::tjson::get_object_item $spec_handle dependencies]
    set deps_simple [::tjson::to_simple $deps_handle]
    set deps [list]
    foreach {dep_name dep_version} $deps_simple {
        lappend deps [list name $dep_name version $dep_version]
    }

    set stat_platforms [get_package_version_stats $package_name $package_version]

    set data [dict merge $req \
        [list \
            package_name $package_name \
            package_version $package_version \
            deps $deps \
            stat_platforms $stat_platforms]]

    set html [::thtml::renderfile package-version.thtml $data]
    set res [::twebserver::build_response 200 text/html $html]
    return $res

}

proc get_package_stats {package_name} {
    set stat_platforms [telemetry_sql {
        SELECT
            pl.os || " " || pl.arch,
            COUNT(*),
            COUNT(CASE WHEN install_outcome = 1 THEN 1 END),
            COUNT(CASE WHEN install_outcome = 0 THEN 1 END)
        FROM req_pkg_install_event ev
        INNER JOIN packages p USING (pkg_id)
        INNER JOIN package_names n USING (pkg_name_id)
        INNER JOIN platforms pl USING (platform_id)
        WHERE n.name = $package_name
        GROUP BY pl.os || pl.arch
    } package_name $package_name]
    # Convert from:
    #     platform1 total1 success1 failure1 platform2 total2 success2 failure2 ...
    # to:
    #     {platform1 total1 success1 failure1} {platform2 total2 success2 failure2} ...
    set stat_platforms [lmap { a b c d } $stat_platforms { list $a $b $c $d }]
    return $stat_platforms
}

proc get_package_version_stats {package_name package_version} {
    set stat_platforms [telemetry_sql {
        SELECT
            pl.os || " " || pl.arch,
            COUNT(*),
            COUNT(CASE WHEN install_outcome = 1 THEN 1 END),
            COUNT(CASE WHEN install_outcome = 0 THEN 1 END)
        FROM req_pkg_install_event ev
        INNER JOIN packages p USING (pkg_id)
        INNER JOIN package_names n USING (pkg_name_id)
        INNER JOIN platforms pl USING (platform_id)
        WHERE n.name = $package_name and p.version = $package_version
        GROUP BY pl.os || pl.arch
    } package_name $package_name package_version $package_version]
    # Convert from:
    #     platform1 total1 success1 failure1 platform2 total2 success2 failure2 ...
    # to:
    #     {platform1 total1 success1 failure1} {platform2 total2 success2 failure2} ...
    set stat_platforms [lmap { a b c d } $stat_platforms { list $a $b $c $d }]
    return $stat_platforms
}

proc get_catchall_handler {ctx req} {
    set res [::twebserver::build_response 404 text/plain "not found"]
    return $res
}
