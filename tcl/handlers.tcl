#
# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.
#

# Return debug handler for the caller.
proc get_debug_handler {ctx req} {
    set data [dict merge $ctx $req]
    set res [::twebserver::build_response 200 "text/plain; charset=utf-8" $data]
    return $res
}

# Record a telemetry event using the configured failure policy.
proc telemetry_event { event_type args } {
    try {
        ::site::database
        ::telemetry::event $event_type {*}$args
    } on error {message options} {
        # Direct-server telemetry was asynchronous and never failed the request.
        # Retain that policy while recording events in the request worker.
        set config [::site::config]
        if {[dict exists $config telemetry_best_effort] && [dict get $config telemetry_best_effort]} {
            puts stderr "Could not record telemetry event: $event_type"
            return
        }
        return -options $options $message
    }
}

# Read aggregate telemetry statistics for display.
proc telemetry_stats {package_name {package_version {}}} {
    # Statistics must not break package pages when the database is unavailable.
    if {[catch {
        ::site::database
        ::telemetry::stats $package_name $package_version
    } result]} {
        puts "Error while accessing telemetry db: $result"
        return {}
    }
    return $result
}

# Attach shared request metadata to a telemetry event.
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

# Record calls to the individual endpoints even when telemetry is disabled.
proc log_legacy_package_request {route req} {
    set fields [dict create event {S legacy_package_request} route [list S $route]]
    foreach key {package_name package_version os machine} {
        if {[dict exists $req pathParameters $key]} {
            dict set fields $key [list S [string range [dict get $req pathParameters $key] 0 254]]
        }
    }
    if {[regexp {^ttrek/([0-9]+\.[0-9]+\.[0-9]+)$} [::responses::header $req User-Agent] -> version]} {
        dict set fields client_version [list S $version]
    }
    catch {puts stderr [::tjson::typed_to_json [list M $fields]]}
}

# Validate and record a submitted telemetry event.
proc post_telemetry_collect_handler {ctx req} {
    log_legacy_package_request post_telemetry_collect $req
    if {[catch {
        [::request_validation::validator telemetry-collect] bind [::topenapi::from_twebserver $req] {
            package_name    {params package_name}
            package_version {params package_version}
            outcome         {body outcome}
            is_toplevel     {body is_toplevel}
            os              {body os}
            arch            {body arch}
        }
    }]} {
        return [::twebserver::build_response 400 text/plain "Invalid telemetry request"]
    }
    set outcome [expr {$outcome eq "success" ? 1 : 0}]

    telemetry_event_common req_pkg_install_event -pkg_name $package_name \
        -pkg_version $package_version -install_outcome $outcome \
        -install_is_toplevel $is_toplevel -os $os -arch $arch

    return [::twebserver::build_response 200 text/plain "ok"]
}

# Return dist handler for the caller.
proc get_dist_handler {ctx req} {
    set arch [::twebserver::get_path_param $req arch]
    set ext [::twebserver::get_path_param $req ext]
    set artifact [::releases::artifact $arch]
    if {$ext ne "" || $artifact eq ""} {
        return [::twebserver::build_response 404 text/plain "Unsupported distribution"]
    }
    set settings [dict get [::site::config] releases]
    if {[dict get $settings bucket] eq "" || [catch {::releases::signed_url $artifact} url]} {
        set response [::twebserver::build_response 503 text/plain "Downloads are temporarily unavailable"]
    } else {
        set os [expr {[string match macos-* $artifact] ? "macos" : "linux"}]
        telemetry_event_common req_dist_get -os $os -arch $arch
        set response [::twebserver::build_redirect 302 $url]
    }
    dict set response headers Cache-Control no-store
    return $response
}

# Return source download handler for the caller.
proc get_source_download_handler {ctx req} {
    set artifact [::twebserver::get_path_param $req artifact]
    if {![regexp {^[a-zA-Z0-9][a-zA-Z0-9._+-]{0,199}-[0-9a-f]{64}\.archive$} $artifact]} {
        return [::twebserver::build_response 404 text/plain "Invalid source archive"]
    }
    # filename is diagnostic metadata only: never use it to select or sign an S3 key.
    if {![catch {::twebserver::get_query_param $req filename} filename]} {
        set entry [list M [dict create event [list S source_download] \
            artifact [list S $artifact] filename [list S $filename]]]
        puts [::tjson::typed_to_json $entry]
    }
    set settings [dict get [::site::config] releases]
    if {[dict get $settings bucket] eq "" || [catch {::releases::source_url $artifact} url]} {
        set response [::twebserver::build_response 503 text/plain "Source downloads are temporarily unavailable"]
    } else {
        set response [::twebserver::build_redirect 302 $url]
    }
    dict set response headers Cache-Control no-store
    return $response
}

# Return release handler for the caller.
proc get_release_handler {ctx req} {
    set target [::releases::artifact [::twebserver::get_path_param $req target]]
    if {$target eq ""} {
        return [::twebserver::build_response 404 text/plain "Unsupported distribution"]
    }
    set settings [dict get [::site::config] releases]
    if {[dict get $settings bucket] eq "" || ![dict exists $settings checksums $target] ||
        [catch {::releases::signed_url $target} url]} {
        set response [::twebserver::build_response 503 text/plain "Release metadata is unavailable"]
    } else {
        set data [list M [dict create version [list S [dict get $settings version]] \
            target [list S $target] url [list S $url] \
            sha256 [list S [string tolower [dict get $settings checksums $target]]]]]
        set response [::twebserver::build_response 200 application/json [::tjson::typed_to_json $data]]
    }
    dict set response headers Cache-Control no-store
    return $response
}

# Join validated path components for a registry resource.
proc path_join {args} {
    set rootdir [file normalize [::site::root]]
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

# Return assets handler for the caller.
proc get_assets_handler {ctx req} {
    set path [dict get $req path]
    set dir [file normalize [::site::root]]
    set filepath [path_join $dir public $path]
    set ext [file extension $filepath]
    if { $ext eq {.css} } {
        set mimetype text/css
    } elseif { $ext eq {.js} } {
        set mimetype application/javascript
    } elseif { $ext eq {.svg} } {
        set mimetype image/svg+xml
    } elseif { $ext eq {.ico} } {
        set mimetype image/vnd.microsoft.icon
    } else {
        return [::assets::unavailable]
    }
    if {[dict exists [::site::config] assets_endpoint]} {
        return [::site::s3_asset $path $mimetype $req]
    }
    if {![file isfile $filepath]} {return [::assets::unavailable]}
    return [::assets::respond $path $req $mimetype [::assets::read_bytes $filepath]]
}

# Return ttrek init handler for the caller.
proc get_ttrek_init_handler {ctx req} {
    set dir [file normalize [::site::root]]
    return [::twebserver::build_response -return_file 200 application/octet-stream $dir/public/ttrek-init]
}

# Return index page handler for the caller.
proc get_index_page_handler {ctx req} {
#    set host [::twebserver::get_header $req host]
#    if { $host ne {} } {
#        lassign [split $host {:}] hostname port
#        if { $hostname eq {get.ttrek.sh} } {
#            return [::twebserver::build_response -return_file 200 application/octet-stream [::site::root]/public/ttrek-init]
#        }
#    }
    set install_command {curl -fsS https://ttrek.sh/init | sh}
    if {[info exists ::env(ENV)] && $::env(ENV) eq "LOCAL"} {
        set install_command {curl -fsS http://localhost:8080/init | ENV=LOCAL sh}
    }
    set data [dict create title {S {Install ttrek}} \
        pagetitle {S {ttrek: registry, website, and command-line interface}} \
        install_command [list S $install_command]]
    set data [dict merge $data [::homepage::data]]
    set html [::views::render index.html.jinja $data]
    set res [::twebserver::build_response 200 "text/html; charset=utf-8" $html]
    return $res
}

# Return packages page handler for the caller.
proc get_packages_page_handler {ctx req} {
    set queries [::recipe_search::request_values $req q]
    if {[llength $queries] > 1 || [string trim [lindex $queries 0]] ne {}} {
        return [get_search_page_handler $ctx $req]
    }
    if {[catch {::recipe_search::request_language $req} language]} {
        return [::twebserver::build_response 400 text/plain "Choose Any, Only TCL, TCL and C/C++, or Only C or C++."]
    }
    if {[catch {::recipe_search::request_after $req} after]} {
        return [::twebserver::build_response 400 text/plain $after]
    }
    if {[catch {::recipe_search::catalog_entries [::recipe_search::database registry_catalog]} catalog]} {
        return [::recipe_search::unavailable]
    }
    set page_size $::recipe_search::page_size
    set names {}
    set start 0
    # catalog_entries supplies ASCII name order, including when the cursor's package was withdrawn.
    dict for {name package} $catalog {
        if {![::recipe_search::matches_language [dict get $package languages] $language]} continue
        lappend names $name
        if {[string compare $name $after] <= 0} {incr start}
    }
    set total [llength $names]
    set end [expr {$start + $page_size - 1}]
    set packages [lmap name [lrange $names $start $end] {dict get $catalog $name}]
    set next_url {}
    if {$end < $total - 1} {
        set next_url [::recipe_search::page_url $language [lindex $names $end]]
    }
    set data [dict create title {S Packages} packages [::recipe_search::cards $packages] \
        next_url [list S $next_url] \
        canonical_path [list S [::recipe_search::page_url $language [lindex $names [expr {$start - 1}]]]] \
        result_count [list N $total] query {S {}} is_search {BOOL 0} error {S {}} \
        tracker [::package_tracker::view $catalog] language_filter {BOOL 1} language [list S $language]]
    set html [::views::render packages.html.jinja $data]
    set res [::twebserver::build_response 200 "text/html; charset=utf-8" $html]
    return $res
}

# Return logo handler for the caller.
proc get_logo_handler {ctx req} {
    set dir [file normalize [::site::root]]
    set filepath [path_join $dir www plume.png]
    set res [::twebserver::build_response -return_file 200 image/png $filepath]
    return $res
}

# Return package versions for the caller.
proc get_package_versions {package_name} {
    ::site::database
    return [lsort -command compare_versions -decreasing [dict keys [::telemetry::registry_versions $package_name]]]
}

# Reject malformed telemetry environment identifiers.
proc validate_environment_id {environment_id} {
    # Check that environment_id consists of 32 characters in
    # the range [1-9a-f] (hexadecimal characters)
    set valid [regexp -nocase {^[0-9a-f]{64}$} $environment_id]
    if { !$valid } {
        puts "WARNING: invalid environment_id \"$environment_id\""
    }
    return $valid
}

# Register a telemetry environment from the validated request.
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

# Return package versions handler for the caller.
proc get_package_versions_handler {ctx req} {
    log_legacy_package_request get_package_versions $req
    set package_name [::twebserver::get_path_param $req package_name]
    telemetry_event_common req_reg_get_pkg -pkg_name $package_name
    if {[catch {
        ::site::database
        ::telemetry::registry_versions $package_name
    } versions]} {
        return [::recipe_search::unavailable]
    }
    set versions_typed {}
    foreach version [lsort -command compare_versions -decreasing [dict keys $versions]] {
        lappend versions_typed $version [dict get $versions $version]
    }
    return [::twebserver::build_response 200 application/json \
        [::tjson::typed_to_json [list M $versions_typed]]]
}

# Collect the feature flags exposed by a recipe.
proc compute_iuse_flags {spec_handle} {
    set names {}
    if {[::tjson::has_object_item $spec_handle iuse]} {
        lassign [::tjson::to_typed [::tjson::get_object_item $spec_handle iuse]] type declared
        if {$type ne "L"} {error "iuse must be an array of unsigned USE flag names"}
        foreach entry $declared {
            lassign $entry type name
            if {$type ne "S" || ![regexp {^[A-Za-z0-9_.][A-Za-z0-9_.-]*$} $name]} {
                error "Invalid unsigned USE flag name in iuse"
            }
            lappend names $name
        }
    }
    foreach node [::tjson::query $spec_handle {$..if}] {
        lassign [::tjson::to_typed $node] type condition
        if {$type ne "S"} {error "Recipe 'if' must be a USE flag string"}
        set tokens [regexp -all -inline {[^\t\n\v\f\r ]+} $condition]
        if {![llength $tokens]} {error "Recipe 'if' must contain a USE flag"}
        foreach flag $tokens {
            if {![regexp {^[+-][A-Za-z0-9_.][A-Za-z0-9_.-]*$} $flag]} {
                error "Invalid USE flag in recipe 'if': $flag"
            }
            lappend names [string range $flag 1 end]
        }
    }
    return [lsort -unique $names]
}

# Lightweight display metadata, without recording a build-recipe download.
proc get_package_languages_handler {ctx req} {
    log_legacy_package_request get_package_languages $req
    set name [::twebserver::get_path_param $req package_name]
    set version [::twebserver::get_path_param $req package_version]
    if {[catch {
        ::site::database
        set rows [::telemetry::rows [::telemetry::registry_query {languages} $name $version]]
    }]} {return [::recipe_search::unavailable]}
    if {![llength $rows]} {return [::twebserver::build_response 404 text/plain "not found"]}
    return [::twebserver::build_response 200 application/json [dict get [lindex $rows 0] languages]]
}

# Return package spec handler for the caller.
proc get_package_spec_handler {ctx req} {
    log_legacy_package_request get_package_spec $req
    set package_name [::twebserver::get_path_param $req package_name]
    set package_version [::twebserver::get_path_param $req package_version]
    set os [::twebserver::get_path_param $req os]
    set machine [::twebserver::get_path_param $req machine]

    if {[catch {
        if {$package_version eq "latest"} {
            set package_version [lindex [get_package_versions $package_name] 0]
        }
        ::site::database
        set stored [::telemetry::registry_recipe $package_name $package_version]
    }]} {return [::recipe_search::unavailable]}
    if {$stored eq {}} {
        return [::twebserver::build_response 404 text/plain "not found"]
    }
    set rendered [render_registry_recipe $stored $package_version $os $machine]
    if {$rendered eq {}} {return [::twebserver::build_response 404 text/plain "not found"]}
    count_registry_recipe $req $package_name $package_version $os $machine
    return [::twebserver::build_response 200 application/json [::tjson::typed_to_json $rendered]]
}

proc render_registry_recipe {stored package_version os machine} {
    ::tjson::parse [dict get $stored recipe] spec_handle
    set deps_typed [::tjson::to_typed [::tjson::get_object_item $spec_handle dependencies]]
    set scripts_typed [::tjson::to_typed [::tjson::get_object_item $spec_handle scripts]]
    set languages {}
    if {[::tjson::has_object_item $spec_handle languages]} {
        set languages [::registry_metadata::languages [::tjson::to_typed [::tjson::get_object_item $spec_handle languages]]]
    }

    set spec_build_handle [::tjson::get_object_item $spec_handle build]
    set platform [string tolower "$os.$machine"]
    if { [::tjson::has_object_item $spec_build_handle $platform] } {
        set spec_build_handle [::tjson::get_object_item $spec_build_handle $platform]
    } elseif { [::tjson::has_object_item $spec_build_handle "default"] } {
        set spec_build_handle [::tjson::get_object_item $spec_build_handle "default"]
    } else {
        return {}
    }

    set spec_build_typed [::tjson::to_typed $spec_build_handle]

    set patches_typed [lindex [::tjson::json_to_typed [dict get $stored patches]] 1]

    set iuse_unique [compute_iuse_flags $spec_handle]

    set iuse_typed [list]
    foreach iuse_flag $iuse_unique {
        lappend iuse_typed [list S $iuse_flag]
    }

    ::tjson::create \
        [list M \
            [list \
                version [list S $package_version] \
                iuse [list L $iuse_typed] \
                dependencies $deps_typed \
                scripts $scripts_typed \
                languages [::views::strings $languages] \
                install_script $spec_build_typed]] \
        result_handle

    if {[::tjson::has_object_item $spec_handle externalDependencies]} {
        ::tjson::add_item_to_object $result_handle externalDependencies \
            [::tjson::to_typed [::tjson::get_object_item $spec_handle externalDependencies]]
    }

    if { $patches_typed ne {} } {
        ::tjson::add_item_to_object $result_handle patches [list M $patches_typed]
    }

    return [::tjson::to_typed $result_handle]
}

proc count_registry_recipe {req package_name package_version os machine} {
    set environment {}
    if {[dict exists $req headers ttrek-environment-id]} {set environment [dict get $req headers ttrek-environment-id]}
    # Count only successfully prepared recipes, using the resolved version.
    # Statistics must not prevent clients from obtaining a working recipe.
    if {[catch {::telemetry::recipe_download $package_name $package_version $os $machine $environment}]} {
        puts stderr "Could not record recipe download statistics"
    }
}

# Order package versions for registry presentation.
proc compare_versions {a b} {
    ::registry_metadata::compare_versions $a $b
}

# Return package page handler for the caller.
proc get_package_page_handler {ctx req} {
    set package_name [::twebserver::get_path_param $req package_name]
    telemetry_event_common req_pkg_get -pkg_name $package_name
    if {[catch {::recipe_search::catalog_entries [::recipe_search::database registry_catalog [list $package_name]]} catalog]} {
        return [::recipe_search::unavailable]
    }
    if {![dict exists $catalog $package_name]} {
        return [::twebserver::build_response 404 text/plain "Package not found"]
    }
    set metadata [dict get $catalog $package_name versions]
    set versions [lsort -command compare_versions -decreasing [dict keys $metadata]]
    set latest [dict get $metadata [lindex $versions 0]]
    set description [string trim [dict get $latest description]]
    set tags [dict get $latest tags]
    set project_url {}
    set candidate [string trim [dict get $latest url]]
    if {[regexp -nocase {^https?://[^/[:space:]?#]+[^[:space:]]*$} $candidate]} {set project_url $candidate}

    set stat_platforms [get_package_stats $package_name]
    set version_rows {}
    foreach version $versions {
        set row [dict get $metadata $version]
        lappend version_rows [::package_tracker::typed_record [dict create version $version \
            date [::package_tracker::date [dict get $row published_at]]]]
    }
    set activity [::package_tracker::read $package_name]
    set activity_fields [dict create available 0]
    set chart_json {}
    if {$activity ne {}} {
        set activity_fields [dict get $activity pkg:$package_name]
        dict set activity_fields available 1
        dict set activity_fields stale [dict get $activity meta stale]
        dict set activity_fields updated [clock format [dict get $activity meta as_of] -format {%b %d, %Y at %H:%M UTC} -gmt true]
        dict set activity_fields window_start [clock format [dict get $activity meta start] -format {%b %d, %Y at %H:%M UTC} -gmt true]
        dict set activity_fields chart_ready [expr {[dict get $activity_fields total] >= 10 && [dict get $activity_fields active_days] >= 3}]
        set chart_json [::package_tracker::json [dict create days [dict get $activity_fields days]]]
    }

    set data [dict create \
        title [list S "Package Overview: $package_name"] \
        package_name [list S $package_name] \
        description [list S $description] \
        tags [::views::strings $tags] \
        languages [::views::strings [dict get $latest languages]] \
        project_url [list S $project_url] \
        license [list S [string trim [dict get $latest license]]] \
        versions [::views::strings $versions] \
        latest_version [list S [lindex $versions 0]] \
        publication_date [list S [::package_tracker::date [dict get $latest first_published_at]]] \
        version_rows [list L $version_rows] \
        activity [::package_tracker::typed_record $activity_fields] \
        activity_json [list S $chart_json] \
        download_platforms [::views::download_stats [get_package_download_stats $package_name]] \
        stat_platforms [::views::platform_stats $stat_platforms]]
    set html [::views::render package.html.jinja $data]
    set res [::twebserver::build_response 200 "text/html; charset=utf-8" $html]
    return $res
}

# Return package version page handler for the caller.
proc get_package_version_page_handler {ctx req} {
    set package_name [::twebserver::get_path_param $req package_name]
    set package_version [::twebserver::get_path_param $req package_version]
    telemetry_event_common req_pkg_version_get -pkg_name $package_name -pkg_version $package_version

    if {[catch {
        ::site::database
        set stored [::telemetry::registry_recipe $package_name $package_version]
        set catalog [::recipe_search::catalog_entries [::telemetry::registry_catalog [list $package_name]]]
    }]} {
        return [::recipe_search::unavailable]
    }
    if {$stored eq {}} {
        return [::twebserver::build_response 404 text/plain "not found"]
    }
    set metadata [dict get $catalog $package_name versions]
    set row [dict get $metadata $package_version]
    set versions [lsort -command compare_versions -decreasing [dict keys $metadata]]
    set project_url {}
    set candidate [string trim [dict get $row url]]
    if {[regexp -nocase {^https?://[^/[:space:]?#]+[^[:space:]]*$} $candidate]} {set project_url $candidate}
    ::tjson::parse [dict get $stored recipe] spec_handle
    set deps_handle [::tjson::get_object_item $spec_handle dependencies]
    set deps_size [::tjson::size $deps_handle]
    set deps [list]
    for {set i 0} {$i < $deps_size} {incr i} {
        set item [::tjson::get_array_item $deps_handle $i]
        #puts [::tjson::to_simple $item]
        set dep_name [::tjson::get_string $item]
        if { [::tjson::is_object $item] && [::tjson::has_object_item $item version] } {
            set dep_version [::tjson::get_valuestring [::tjson::get_object_item $item "version"]]
            set dep_if_use_flags [::tjson::get_valuestring [::tjson::get_object_item $item "if"]]
        } else {
            set dep_version [::tjson::get_valuestring $item]
            set dep_if_use_flags ""
        }
        lappend deps [list M [list name [list S $dep_name] version [list S $dep_version] condition [list S $dep_if_use_flags]]]
    }

    set stat_platforms [get_package_version_stats $package_name $package_version]

    set data [dict create \
        title [list S "Package Version: $package_name@$package_version"] \
        package_name [list S $package_name] \
        package_version [list S $package_version] \
        description [list S [dict get $row description]] \
        tags [::views::strings [dict get $row tags]] \
        languages [::views::strings [dict get $row languages]] \
        license [list S [dict get $row license]] \
        project_url [list S $project_url] \
        publication_date [list S [::package_tracker::date [dict get $row published_at]]] \
        versions [::views::strings $versions] \
        latest_version [list S [lindex $versions 0]] \
        deps [list L $deps] \
        download_platforms [::views::download_stats [get_package_download_stats $package_name $package_version]] \
        stat_platforms [::views::platform_stats $stat_platforms]]

    set html [::views::render package-version.html.jinja $data]
    set res [::twebserver::build_response 200 "text/html; charset=utf-8" $html]
    return $res

}

# Return package stats for the caller.
proc get_package_download_stats {name {version {}}} {
    if {[catch {
        ::site::database
        ::telemetry::download_stats $name $version
    } result]} {
        puts stderr "Could not read recipe download statistics"
        return {}
    }
    return $result
}

# Return package stats for the caller.
proc get_package_stats {package_name} {
    telemetry_stats $package_name
}

# Return package version stats for the caller.
proc get_package_version_stats {package_name package_version} {
    telemetry_stats $package_name $package_version
}

# Return catchall handler for the caller.
proc get_catchall_handler {ctx req} {
    set res [::twebserver::build_response 404 text/plain "not found"]
    return $res
}

proc registry_capabilities_handler {ctx req} {
    return [::twebserver::build_response 200 application/json {{"batch":1}}]
}

# Leave headroom for the Lambda HTTP response envelope. Clients split a 413
# before any download counters are recorded. Singletons retain the GET limit.
proc registry_batch_response {result} {
    set json [::tjson::typed_to_json [list M $result]]
    if {[dict size $result] > 1 && [string length [encoding convertto utf-8 $json]] > 2 * 1024 * 1024} {
        return [::twebserver::build_response 413 text/plain "Split the registry batch"]
    }
    return [::twebserver::build_response 200 application/json $json]
}

proc registry_packages_handler {ctx req} {
    if {[catch {
        [::request_validation::validator registry-packages] bind [::topenapi::from_twebserver $req] {
            names {body names} mode {body mode}
        }
    }]} {return [::twebserver::build_response 400 text/plain "Invalid package batch"]}
    set names [lsort -unique $names]
    set result {}
    foreach name $names {dict set result $name {BOOL 0}}
    if {[catch {
        ::site::database
        set columns [expr {$mode eq "exists" ? "name" : "name version recipe"}]
        foreach row [::telemetry::registry_batch_rows $columns $names] {
            set name [dict get $row name]
            if {$mode eq "exists"} {
                dict set result $name {BOOL 1}
            } else {
                set recipe [lindex [::tjson::json_to_typed [dict get $row recipe]] 1]
                dict set versions $name [dict get $row version] [dict get $recipe dependencies]
            }
        }
        if {[info exists versions]} {
            dict for {name entries} $versions {dict set result $name [list M $entries]}
        }
    }]} {return [::recipe_search::unavailable]}
    set response [registry_batch_response $result]
    if {[dict get $response statusCode] == 200 && [dict exists $req headers ttrek-environment-id]} {
        foreach name $names {telemetry_event_common req_reg_get_pkg -pkg_name $name}
    }
    return $response
}

proc registry_plan_handler {ctx req} {
    if {[catch {
        [::request_validation::validator registry-plan] bind [::topenapi::from_twebserver $req] {
            items {body items} os {body os} arch {body arch}
        }
    }]} {return [::twebserver::build_response 400 text/plain "Invalid plan batch"]}
    set result {}
    set groups {}
    foreach item $items {
        set name [dict get $item name]
        set version [dict get $item version]
        set field [dict get $item field]
        set key "$name@$version"
        if {[dict exists $result $key]} {return [::twebserver::build_response 400 text/plain "Duplicate plan item"]}
        dict set result $key {BOOL 0}
        dict lappend groups $field [list $name $version]
    }
    set served {}
    if {[catch {
        ::site::database
        dict for {field pairs} $groups {
            set columns [expr {$field eq "recipe" ? "name version pkg_id recipe patches" : "name version languages"}]
            foreach row [::telemetry::registry_batch_rows $columns {} $pairs] {
                set name [dict get $row name]
                set version [dict get $row version]
                if {$field eq "languages"} {
                    dict set result "$name@$version" [::tjson::json_to_typed [dict get $row languages]]
                } else {
                    set recipe [render_registry_recipe $row $version $os $arch]
                    if {$recipe eq {}} continue
                    dict set result "$name@$version" $recipe
                    lappend served [dict get $row pkg_id]
                }
            }
        }
    }]} {return [::recipe_search::unavailable]}
    set response [registry_batch_response $result]
    if {[dict get $response statusCode] == 200 && [llength $served]} {
        set environment {}
        if {[dict exists $req headers ttrek-environment-id]} {set environment [dict get $req headers ttrek-environment-id]}
        if {[catch {::telemetry::count_recipe_ids $served $os $arch $environment}]} {
            puts stderr "Could not record recipe download statistics"
        }
    }
    return $response
}

proc telemetry_batch_handler {ctx req} {
    if {[catch {
        [::request_validation::validator telemetry-batch] bind [::topenapi::from_twebserver $req] {events {body events}}
    }]} {return [::twebserver::build_response 400 text/plain "Invalid telemetry batch"]}
    foreach event $events {
        dict with event {
            telemetry_event_common req_pkg_install_event -pkg_name $name -pkg_version $version \
                -install_outcome [expr {$outcome eq "success"}] -install_is_toplevel $is_toplevel -os $os -arch $arch
        }
    }
    return [::twebserver::build_response 200 text/plain "ok"]
}
