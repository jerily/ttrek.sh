proc get_debug_handler {ctx req} {
    set data [dict merge $ctx $req]
    set res [::twebserver::build_response 200 "text/plain; charset=utf-8" $data]
    return $res
}

proc telemetry_event { event_type args } {
    set config [::site::config]
    if {[dict exists $config telemetry_thread_id]} {
        thread::send -async [dict get $config telemetry_thread_id] \
            [list ::telemetry::event $event_type {*}$args]
    } else {::telemetry::event $event_type {*}$args}
}

proc telemetry_stats {package_name {package_version {}}} {
    # Statistics must not break package pages when the database is unavailable.
    if {[catch {
        set config [::site::config]
        set command [list ::telemetry::stats $package_name $package_version]
        if {[dict exists $config telemetry_thread_id]} {
            thread::send [dict get $config telemetry_thread_id] $command
        } else {{*}$command}
    } result]} {
        puts "Error while accessing telemetry db: $result"
        return {}
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

proc get_ttrek_init_handler {ctx req} {
    set dir [file normalize [::site::root]]
    return [::twebserver::build_response -return_file 200 application/octet-stream $dir/public/ttrek-init]
}

proc get_index_page_handler {ctx req} {
#    set host [::twebserver::get_header $req host]
#    if { $host ne {} } {
#        lassign [split $host {:}] hostname port
#        if { $hostname eq {get.ttrek.sh} } {
#            return [::twebserver::build_response -return_file 200 application/octet-stream [::site::root]/public/ttrek-init]
#        }
#    }
    set install_command {curl --proto '=https' --tlsv1.2 -sSf https://ttrek.sh/init | sh}
    if {[info exists ::env(ENV)] && $::env(ENV) eq "LOCAL"} {
        set install_command {curl -fsS http://localhost:8080/init | ENV=LOCAL sh}
    }
    set data [dict create title {S {Install ttrek}} \
        pagetitle {S {ttrek: registry, website, and command-line interface}} \
        install_command [list S $install_command]]
    set html [::views::render index.html.jinja $data]
    set res [::twebserver::build_response 200 "text/html; charset=utf-8" $html]
    return $res
}

proc get_registry_dir {} {
    return [dict get [::site::config] registry_dir]
}

proc get_packages_page_handler {ctx req} {
    if {[catch {::recipe_search::catalog_entries [::recipe_search::database registry_catalog]} catalog]} {
        return [::recipe_search::unavailable]
    }
    set packages [dict values $catalog]
    set data [dict create title {S Packages} packages [::recipe_search::cards $packages] \
        result_count [list N [llength $packages]] query {S {}} is_search {BOOL 0} error {S {}}]
    set html [::views::render packages.html.jinja $data]
    set res [::twebserver::build_response 200 "text/html; charset=utf-8" $html]
    return $res
}

proc get_logo_handler {ctx req} {
    set dir [file normalize [::site::root]]
    set filepath [path_join $dir www plume.png]
    set res [::twebserver::build_response -return_file 200 image/png $filepath]
    return $res
}

proc get_package_versions {registry_dir package_name} {
    set versions [list]
    foreach path [glob -nocomplain -type d -directory [file join $registry_dir $package_name] *] {
        lappend versions [file tail $path]
    }
    return [lsort -command compare_versions -decreasing $versions]
}

proc get_package_version_dependencies {registry_dir package_name version} {
    set deps [list]
    set spec_path [file join $registry_dir $package_name $version ttrek.json]
    if {![file exists $spec_path]} {
        error "spec file not found: $package_name $version"
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

proc get_latest_version {registry_dir package_name} {
    set versions [get_package_versions $registry_dir $package_name]
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
    set registry_dir [get_registry_dir]
    set package_name [::twebserver::get_path_param $req package_name]
    telemetry_event_common req_reg_get_pkg -pkg_name $package_name
    set versions_typed [list]
    foreach version [get_package_versions $registry_dir $package_name] {
        set deps_typed [get_package_version_dependencies $registry_dir $package_name $version]
        lappend versions_typed $version $deps_typed
    }
    return [::twebserver::build_response 200 application/json \
        [::tjson::typed_to_json [list M $versions_typed]]]
}

proc compute_iuse_flags {spec_handle} {
    set if_use_nodes [::tjson::query $spec_handle {$..if}]

    set iuse_list [list]
    foreach if_use_node $if_use_nodes {
        lappend iuse_list [::tjson::get_valuestring $if_use_node]
    }
    set iuse_unique [lsort -unique $iuse_list]
    return $iuse_unique
}

proc resolve_recipe_scripts {scripts_typed directory} {
    lassign $scripts_typed type scripts
    if {$type ne "M"} {error "recipe scripts must be an object"}
    set result {}
    dict for {name script} $scripts {
        if {$name eq {}} {error "recipe script names must not be empty"}
        lassign $script type value
        if {$type eq "S"} {
            lappend result $name $script
            continue
        }
        if {$type ne "M" || ![dict exists $value file] ||
            [dict size $value] != 1 + [dict exists $value args] ||
            [lindex [dict get $value file] 0] ne "S"} {
            error "recipe scripts must have string bodies or a file reference with optional args"
        }
        set presets {}
        if {[dict exists $value args]} {
            lassign [dict get $value args] args_type args
            if {$args_type ne "L"} {error "recipe script args must be an array of strings"}
            foreach arg $args {
                lassign $arg arg_type arg_value
                if {$arg_type ne "S"} {error "recipe script args must be an array of strings"}
                append presets " '" [string map [list ' {'"'"'}] $arg_value] "'"
            }
        }
        set filename [lindex [dict get $value file] 1]
        if {![regexp {^[A-Za-z0-9._+-]+$} $filename] || $filename in {. ..}} {
            error "Invalid recipe script filename"
        }
        set path [file join $directory $filename]
        if {![file exists $path] || [file type $path] ne "file"} {
            error "Recipe script must be a regular file in its recipe directory: $path"
        }
        set fp [open $path rb]
        try {
            set body [encoding convertfrom utf-8 [read $fp]]
        } finally {
            close $fp
        }
        if {[string first \u0000 $body] >= 0} {error "Recipe script must not contain NUL bytes"}
        if {$presets ne {}} {
            # Return a self-contained shell body with literal presets before runtime arguments.
            set position 0
            if {[string range $body 0 1] eq "#!"} {
                set position [string first \n $body]
                if {$position < 0} {
                    append body \n
                    set position [string length $body]
                } else {incr position}
            }
            set body "[string range $body 0 $position-1]set --$presets \"\$@\"\n[string range $body $position end]"
        }
        lappend result $name [list S $body]
    }
    return [list M $result]
}

proc get_package_spec_handler {ctx req} {
    set package_name [::twebserver::get_path_param $req package_name]
    set package_version [::twebserver::get_path_param $req package_version]
    set os [::twebserver::get_path_param $req os]
    set machine [::twebserver::get_path_param $req machine]

    telemetry_event_common req_reg_get_pkg_spec \
        -pkg_name $package_name -pkg_version $package_version \
        -os $os -arch $machine

    set registry_dir [get_registry_dir]

    puts "package_name: $package_name package_version: $package_version os: $os machine: $machine"

    if { $package_version eq "latest" } {
        set package_version [get_latest_version $registry_dir $package_name]
        if { $package_version eq {} } {
            return [::twebserver::build_response 404 text/plain "not found"]
        }
    }

    set spec_path [file join $registry_dir $package_name $package_version ttrek.json]
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

    set scripts_typed [list M {}]
    if {[::tjson::has_object_item $spec_handle scripts]} {
        set scripts_typed [resolve_recipe_scripts \
            [::tjson::to_typed [::tjson::get_object_item $spec_handle scripts]] [file dirname $spec_path]]
    }

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
    foreach patch_path [glob -nocomplain -type f -directory [file join $registry_dir $package_name $package_version] *.diff] {
        set fp [open $patch_path]
        set data [read $fp]
        close $fp
        lappend patches_typed [file tail $patch_path] [list S [::twebserver::base64_encode $data]]
    }

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

    set data [dict create \
        title [list S "Package Overview: $package_name"] \
        package_name [list S $package_name] \
        description [list S $description] \
        tags [::views::strings $tags] \
        project_url [list S $project_url] \
        license [list S [string trim [dict get $latest license]]] \
        versions [::views::strings $versions] \
        stat_platforms [::views::platform_stats $stat_platforms]]
    set html [::views::render package.html.jinja $data]
    set res [::twebserver::build_response 200 "text/html; charset=utf-8" $html]
    return $res
}

proc get_package_version_page_handler {ctx req} {
    set package_name [::twebserver::get_path_param $req package_name]
    set package_version [::twebserver::get_path_param $req package_version]
    telemetry_event_common req_pkg_version_get -pkg_name $package_name -pkg_version $package_version

    set registry_dir [get_registry_dir]

    set spec_path [file join $registry_dir $package_name $package_version ttrek.json]
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
        deps [list L $deps] \
        stat_platforms [::views::platform_stats $stat_platforms]]

    set html [::views::render package-version.html.jinja $data]
    set res [::twebserver::build_response 200 "text/html; charset=utf-8" $html]
    return $res

}

proc get_package_stats {package_name} {
    telemetry_stats $package_name
}

proc get_package_version_stats {package_name package_version} {
    telemetry_stats $package_name $package_version
}

proc get_catchall_handler {ctx req} {
    set res [::twebserver::build_response 404 text/plain "not found"]
    return $res
}
