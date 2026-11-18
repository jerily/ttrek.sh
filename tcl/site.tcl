# 
# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.
# 

# Register the package and load its dependencies.
package require Tcl 9.1
package require twebserver
package require tjson
package require tpathexp 1.2.0

namespace eval ::site {
    variable settings
    variable router
    variable services {}
    variable starting {}
    variable private {}
    variable middleware_ready false
    variable database_ready false
}

source [file join [file dirname [info script]] private-config.tcl]
if {![llength [info commands ::site_profile::begin]]} {
    source [file join [file dirname [info script]] profile.tcl]
}

foreach module {assets browser-assets responses templates releases content-images request-validation search handlers request-monitor homepage accounts forum package-tracker} {
    uplevel #0 [list source [file join [file dirname [info script]] $module.tcl]]
}

# Return the current worker configuration.
proc ::site::config {} {variable settings; return $settings}
# Return the configured application root directory.
proc ::site::root {} {dict get [config] rootdir}

# Packaged production templates are validated before deployment. Development
# keeps the early diagnostics, including when ENV has not been set by a host.
proc ::site::validate_templates {} {
    expr {![info exists ::env(ENV)] || $::env(ENV) ne "PROD"}
}

# Apply the worker settings and initialize shared site resources.
proc ::site::configure {config} {
    ::private_config::assert_public $config
    if {![dict exists $config loading]} {dict set config loading lazy}
    if {[dict get $config loading] ni {lazy eager}} {error "loading must be lazy or eager"}
    if {[info exists ::accounts::mount] && $::accounts::mount ne {}} {::web::user::release $::accounts::mount}
    set ::accounts::mount {}; set ::accounts::store {}
    variable settings $config
    variable services {}
    variable starting {}
    variable middleware_ready false
    variable database_ready false
    set imageSettings {}
    if {[dict exists $config content_images]} {set imageSettings [dict get $config content_images]}
    ::assets::configure $imageSettings
    ::views::init [file join [root] www] false
    ::homepage::configure [root]
    # Defer database reads until a catalog request, so provisioning tasks can
    # initialize a new deployment before its first public request.
    ::recipe_search::reset
}

# Register the complete route table without opening storage or preparing templates.
proc ::site::mount {router args} {
    variable private [::private_config::site {*}$args]
    variable settings
    ::private_config::assert_public $settings
    set tracker {}
    if {[dict exists $settings package_tracker]} {set tracker [dict get $settings package_tracker]}
    ::package_tracker::configure $tracker -secret_config [dict get $private redis]
    foreach package {web-static-wiki web-static-blog treqmon} {package require ${package}::routes 1.0}
    if {[dict exists $settings account]} {
        package require web-user::routes 1.0
        package require web-forum::routes 1.0
        set account [dict get $settings account]
        set display [dict get $account display]
        bind_routes $router account [::web::user::route_specs [dict get $display prefix] @mount $display [dict get $account policy]]
        set prefix /forum
        if {[dict exists $settings forum prefix]} {set prefix [dict get $settings forum prefix]}
        bind_routes $router forum [::web::forum::route_specs $prefix @mount]
    }
    bind_routes $router wiki [::web::static::wiki::route_specs /docs @mount]
    bind_routes $router blog [::web::static::blog::route_specs /blog @mount]
    bind_routes $router monitor [::treqmon::route_specs /request-monitor @mount]
    # Collection surrounds authentication and rate limiting, including rejected requests.
    $router add_middleware -enter_proc ::site::middleware_enter
    if {[dict exists $settings treqmon]} {
        $router add_middleware -enter_proc ::treqmon::middleware::enter -leave_proc ::treqmon::middleware::leave
    }
    if {[dict exists $settings treqmon] && [dict exists $settings account]} {
        $router add_middleware -enter_proc ::accounts::monitor_enter
    }
    if {[dict exists $settings tratelimit]} {
        $router add_middleware -enter_proc ::tratelimit::middleware::enter
        $router add_middleware -enter_proc [list ::site::sensitive_enter $router]
    }
    $router add_middleware -enter_proc ::accounts::monitor_authorize
    foreach {method pattern handler name} [source [file join [root] tcl routes.tcl]] {
        set hooks {}
        if {[dict exists $settings tratelimit]} {
            set hooks [list -enter_proc [list ::tratelimit::middleware::enter_route $name]]
        }
        $router add $method $pattern [list ::site::invoke $handler $name] -strict true {*}$hooks
    }
}

proc ::site::bind_routes {router kind routes} {
    foreach route $routes {
        lassign $route method pattern handler
        $router add $method $pattern [list ::site::package_dispatch $kind $handler] -strict true
    }
}

proc ::site::middleware_enter {context request} {
    variable middleware_ready
    variable settings
    variable private
    if {!$middleware_ready} {
        try {
            foreach package {tratelimit treqmon} {
                if {[dict exists $settings $package]} {
                    package require $package
                    ::${package}::init_middleware [middleware_config [dict get $settings $package] [dict get $private redis]]
                }
            }
            set middleware_ready true
        } on error {message options} {
            foreach package {tratelimit treqmon} {catch {::${package}::middleware::valkeystore::shutdown}}
            return -options $options $message
        }
    }
    return $request
}

proc ::site::package_dispatch {kind handler request context params} {
    # Asset handlers need implementation code, but no database or mount resources.
    if {"@mount" ni $handler || [lindex $handler end] eq "asset"} {
        lassign [::views::package_info $kind] package
        package require $package
        set config {}
    } else {set config [service $kind]}
    set command [lmap argument $handler {expr {$argument eq "@mount" ? $config : $argument}}]
    {*}$command $request $context $params
}

# Open the SQL connection only for a consumer that actually needs it.
proc ::site::database {} {
    variable settings
    variable private
    variable database_ready
    if {$database_ready} {return [dict get $settings content_connection]}
    if {![llength [info commands ::telemetry::connect]]} {source [file join [root] tcl telemetry.tcl]}
    if {![dict exists $settings content_connection]} {
        ::telemetry::connect [dict get $settings content_database] -secret_config [dict get $private postgres]
        dict set settings content_connection $::telemetry::connection
    }
    set ::telemetry::connection [dict get $settings content_connection]
    set ::telemetry::dialect [::tpersist::db_dialect $::telemetry::connection]
    dict for {name parameters} $::telemetry::event_list {dict set ::telemetry::event_list $name [lsort $parameters]}
    set database_ready true
    return $::telemetry::connection
}

# A failed initialization remains retryable. Successful resources are reused by
# this worker, without modifying the router or touching other feature stores.
proc ::site::service {kind} {
    variable services
    variable starting
    variable settings
    variable private
    if {[dict exists $services $kind]} {return [dict get $services $kind]}
    if {[dict exists $starting $kind]} {error "Service initialization is already in progress: $kind"}
    dict set starting $kind 1
    try {
        switch -- $kind {
            account {
                database
                set value [::accounts::prepare $settings -secret_config [dict get $private account]]
            }
            forum {
                service account
                set value [::site_forum::prepare $settings]
            }
            wiki - blog {
                set images {}
                if {[dict exists $settings content_images]} {set images [dict get $settings content_images]}
                set store [::content_images::database_store $kind [database] $images]
                set prefix [dict get {wiki /docs blog /blog} $kind]
                set value [::web::static::${kind}::prepare_mount -store $store -prefix $prefix -config [::views::mount_settings $kind]]
            }
            monitor {
                package require treqmon
                set display [dict merge [::views::mount_settings monitor] [dict create chart_script [::assets::url /js/chart.umd.js]]]
                set value [::treqmon::prepare_mount -prefix /request-monitor -middleware false \
                    -include_active_users [dict exists $settings account] -config $display]
            }
            default {error "Unknown service: $kind"}
        }
        dict set services $kind $value
        return $value
    } finally {dict unset starting $kind}
}

# Eager mode preloads code and templates through the same paths. Connections
# and account key handles still belong to the first request that needs them.
proc ::site::prewarm {} {
    foreach package {web-static-wiki web-static-blog treqmon tratelimit pure-tcl-aws-s3 ttrie ttrigrams topenapi} {package require $package}
    if {[dict exists [config] account]} {
        foreach package {web-user web-forum bcrypt tmfa tqrcodegen tcaptcha pure-tcl-oauth2-client pure-tcl-aws-ses pure-tcl-aws-sqs pure-tcl-aws-lambda} {package require $package}
        ::web::user::session_backend
    }
    ::views::prewarm
}

# Package-owned routes have no site route hook. Resolve the actual handler so
# captures, query strings and different topic IDs cannot create fresh buckets.
proc ::site::sensitive_enter {router context request} {
    set method [dict get $request method]
    set match [$router match $method [dict get $request path]]
    if {[dict get $match statusCode] != 200} {return $request}
    set command [dict get $match handler]
    if {[lindex $command 0] eq "::site::package_dispatch"} {set command [lindex $command 2]}
    set handler [lindex $command 0]
    set action [namespace tail $handler]
    if {[string match ::web::user::* $handler]} {
        return [::tratelimit::middleware::enter_route account_$action $context $request]
    }
    if {[string match ::web::forum::* $handler] && ($method eq "POST" || $action in {new moderate})} {
        return [::tratelimit::middleware::enter_route forum_$action $context $request]
    }
    return $request
}

# Build a router and mount the configured worker services.
proc ::site::init_worker {settings args} {
    variable router
    configure $settings
    set router [::tpathexp::router]
    try {
        mount $router {*}$args
        if {[dict get [config] loading] eq "eager"} {prewarm}
    } on error {message options} {
        $router destroy
        unset router
        return -options $options $message
    }
    return $router
}

# Both adapters build routes during initialization; loading policy only changes
# when implementation dependencies and template caches are populated.
proc ::site::prepare_worker {config args} {init_worker $config {*}$args}
proc ::site::ensure_worker {} {variable router; return $router}

# Attach the route name and invoke its handler.
proc ::site::invoke {handler name request context params} {
    dict set context route_name $name
    $handler $context $request
}

# Normalize the request and preserve package-owned response policies.
proc ::site::dispatch {router request {context {}}} {
    set profiling [::site_profile::begin $context]
    set code [catch {
        package require web-user::request 1.0
        set method [expr {[dict exists $request method] ? [dict get $request method] : [dict get $request httpMethod]}]
        ::web::user::with_request $method [list dispatch_request $router $request $context]
    } result options]
    if {$profiling} {::site_profile::finish $code}
    return -options $options $result
}

proc ::site::dispatch_request {router request context} {
    if {![dict exists $request method]} {dict set request method [dict get $request httpMethod]}
    dict set request httpMethod [dict get $request method]
    set request [dict merge [dict create headers {} queryString {} version HTTP/1.1 \
        url [dict get $request path]] $request]
    set host [::responses::header $request Host]
    if {$host ne {} && ![string equal -nocase $host ttrek.sh] &&
        !([info exists ::env(ENV)] && $::env(ENV) eq "LOCAL")} {
        set path [dict get $request path]
        if {![string match /* $path]} {set path /$path}
        set location https://ttrek.sh$path
        if {[dict get $request queryString] ne {}} {append location ?[dict get $request queryString]}
        set location [string map [list \r %0D \n %0A] $location]
        set response [::twebserver::build_redirect 302 $location]
        dict set response headers Cache-Control no-store
        return $response
    }
    set context [dict merge {addr 127.0.0.1 port 8080} $context]
    # Render HEAD as GET so compression and validators select identical headers.
    set routed_request $request
    if {[dict get $request method] eq "HEAD"} {
        dict set routed_request method GET
    }
    set response [$router dispatch $routed_request $context]
    set content_type {}
    set has_policy 0
    dict for {name value} [dict get $response headers] {
        if {[string equal -nocase $name Content-Type]} {set content_type $value}
        if {[string equal -nocase $name Cache-Control]} {set has_policy 1}
    }
    if {[string match {text/html*} $content_type]} {
        set response [::assets::allow_cdn $response]
        dict set response body [::views::stamp_year [dict get $response body]]
        # Keep package-owned no-store policies; ordinary site HTML revalidates
        # so a deployment promptly switches browsers to the new asset URLs.
        if {!$has_policy} {dict set response headers Cache-Control no-cache}
        set response [::accounts::navigation $request $response $context]
    }
    return [::responses::prepare $request $response]
}

# Serve a native connection and report unexpected handler failures.
proc ::site::process_conn {context request} {
    variable router
    if {[catch {dispatch [ensure_worker] $request $context} response options]} {
        puts stderr [dict get $options -errorinfo]
        set response [::twebserver::build_response 500 text/plain {Unable to serve this request.}]
    }
    ::twebserver::return_response [dict get $context conn] $response
}

# Supply credentials only to the internal backend initializer.
proc ::site::middleware_config {config secret} {
    if {[dict exists $config store valkeystore]} {
        dict set config store valkeystore [::private_config::password [dict get $config store valkeystore] -secret_config $secret]
    }
    return $config
}
