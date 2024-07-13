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
::twebserver::add_route -strict $router GET /init get_ttrek_init_handler
::twebserver::add_route -strict $router GET /packages get_packages_page_handler
::twebserver::add_route -prefix $router GET /(css|js|assets)/ get_css_or_js_or_assets_handler
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

proc path_join {args} {
    set rootdir [file normalize [::twebserver::get_rootdir]]
    set path ""
    foreach arg $args {
        set parts [file split $arg]
        foreach part $parts {
            if { $part eq {..} } {
                error "path_join: path \"$arg\" contains \"..\""
            }
            append path "/" $part
        }
    }
    set normalized_path [file normalize $path]
    if { [string range $normalized_path 0 [expr { [string length $rootdir] - 1}]] ne $rootdir } {
        error "path_join: path \"$normalized_path\" is not under rootdir \"$rootdir\""
    }
    return $normalized_path
}

proc get_css_or_js_or_assets_handler {ctx req} {
    set path [dict get $req path]
    set dir [file normalize [::thtml::get_rootdir]]
    set filepath [path_join $dir public $path]
#    puts filepath=$filepath
    set ext [file extension $filepath]
    if { $ext eq {.css} } {
        set mimetype text/css
    } elseif { $ext eq {.js} } {
        set mimetype application/javascript
    } elseif { $ext eq {.svg} } {
        set mimetype image/svg+xml
    } else {
        error "get_css_or_js_handler: unsupported extension \"$ext\""
    }
    set res [::twebserver::build_response -return_file 200 $mimetype $filepath]
    return $res
}

proc get_ttrek_init_handler {ctx req} {
    set dir [file normalize [::thtml::get_rootdir]]
    return [::twebserver::build_response -return_file 200 application/octet-stream $dir/public/ttrek-init]
    return $res
}

proc get_index_page_handler {ctx req} {
#    set host [::twebserver::get_header $req host]
#    if { $host ne {} } {
#        lassign [split $host {:}] hostname port
#        if { $hostname eq {get.ttrek.sh} } {
#            return [::twebserver::build_response -return_file 200 application/octet-stream [::twebserver::get_rootdir]/public/ttrek-init]
#        }
#    }
    set data [dict merge $req [list title "Install ttrek"]]
    set html [::thtml::renderfile index.thtml $data]
    set res [::twebserver::build_response 200 "text/html; charset=utf-8" $html]
    return $res
}

proc get_packages_page_handler {ctx req} {
    set package_names [list]
    foreach path [glob -nocomplain -type d [file join [::twebserver::get_rootdir] registry/*]] {
        lappend package_names [file tail $path]
    }
    set data [dict merge $req [list title "Packages" package_names [lsort $package_names]]]
    set html [::thtml::renderfile packages.thtml $data]
    set res [::twebserver::build_response 200 "text/html; charset=utf-8" $html]
    return $res
}

proc get_logo_handler {ctx req} {
    set dir [file normalize [::thtml::get_rootdir]]
    set filepath [path_join $dir www plume.png]
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
    return [::tjson::to_typed $deps_handle]
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
        set deps_typed [get_package_version_dependencies $dir $package_name $version]
        lappend versions_typed $version $deps_typed
    }
    return [::twebserver::build_response 200 application/json \
        [::tjson::typed_to_json [list M $versions_typed]]]
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

    set spec_build_typed [::tjson::to_typed $spec_build_handle]

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
                install_script $spec_build_typed]] \
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
    set res [::twebserver::build_response 200 "text/html; charset=utf-8" $html]
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
    set res [::twebserver::build_response 200 "text/html; charset=utf-8" $html]
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
