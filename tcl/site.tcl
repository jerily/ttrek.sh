# 
# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.
# 

# Register the package and load its dependencies.
package require Tcl 9.1
package require twebserver
package require tjson
package require tratelimit 1.1.1
package require treqmon 2.3.1
package require web-static-wiki 0.1.11
package require web-static-blog 0.1.10
package require tpathexp 1.2.0

namespace eval ::site {
    variable settings
    variable router
}

source [file join [file dirname [info script]] private-config.tcl]

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
    variable settings $config
    set imageSettings {}
    if {[dict exists $config content_images]} {set imageSettings [dict get $config content_images]}
    ::assets::configure $imageSettings
    ::views::init [file join [root] www] [validate_templates]
    ::homepage::configure [root]
    # Defer database reads until a catalog request, so provisioning tasks can
    # initialize a new deployment before its first public request.
    ::recipe_search::reset
}

# Each worker owns a router. Content is queried per request in both modes.
proc ::site::mount {router args} {
    set secret [::private_config::site {*}$args]
    variable settings
    ::private_config::assert_public $settings
    set tracker {}
    if {[dict exists $settings package_tracker]} {set tracker [dict get $settings package_tracker]}
    ::package_tracker::configure $tracker -secret_config [dict get $secret redis]
    if {[dict exists $settings tratelimit]} {
        ::tratelimit::init_middleware [::site::middleware_config [dict get $settings tratelimit] [dict get $secret redis]]
    }
    if {[dict exists $settings treqmon]} {
        ::treqmon::init_middleware [::site::middleware_config [dict get $settings treqmon] [dict get $secret redis]]
    }
    set templates $::views::templates
    set imageSettings {}
    if {[dict exists [config] content_images]} {
        set imageSettings [dict get [config] content_images]
    }
    if {![dict exists $settings content_connection]} {
        dict set settings content_connection [::content_images::connect [dict get $settings content_database] -secret_config [dict get $secret postgres]]
    }
    if {[dict exists $settings account]} {
        ::accounts::mount $router $settings $templates -secret_config [dict get $secret account]
        ::site_forum::mount $router $settings $templates
    }
    set stores [::content_images::database_stores [dict get $settings content_connection] $imageSettings]
    foreach {kind directory prefix} {wiki docs /docs blog blog /blog} {
        set store [dict get $stores $kind]
        ::web::static::${kind}::mount $router -store $store -prefix $prefix \
            -config [dict create validate_templates [validate_templates] master_template [dict get $templates ${directory}-master.html.jinja] \
                templates [dict create master.html.jinja [dict get $templates master.html.jinja]]]
    }
    set monitor_master request-monitor-master.html.jinja
    if {[dict exists [config] request_monitor master_template]} {
        set monitor_master [dict get [config] request_monitor master_template]
    }
    ::treqmon::mount $router -prefix /request-monitor \
        -middleware [dict exists $settings treqmon] \
        -include_active_users [dict exists $settings account] \
        -config [dict create validate_templates [validate_templates] master_template [dict get $templates $monitor_master] \
            templates [dict create master.html.jinja [dict get $templates master.html.jinja]] \
            chart_script [::assets::url /js/chart.umd.js]]
    if {[dict exists $settings treqmon] && [dict exists $settings account]} {
        $router add_middleware -enter_proc ::accounts::monitor_enter
    }
    # Monitoring is outermost so rate-limit responses are recorded as well.
    if {[dict exists $settings tratelimit]} {
        ::tratelimit::mount $router
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

# Package-owned routes have no site route hook. Resolve the actual handler so
# captures, query strings and different topic IDs cannot create fresh buckets.
proc ::site::sensitive_enter {router context request} {
    set method [dict get $request method]
    set match [$router match $method [dict get $request path]]
    if {[dict get $match statusCode] != 200} {return $request}
    set handler [lindex [dict get $match handler] 0]
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
    } on error {message options} {
        $router destroy
        unset router
        return -options $options $message
    }
}

# Keep credentials out of public settings while postponing the SQL connection
# and the mounts that borrow it until this interpreter receives its first event.
proc ::site::prepare_worker {config args} {
    ::private_config::assert_public $config
    variable pending_secrets [::private_config::site {*}$args]
    variable settings $config
    variable starting 0
}

proc ::site::ensure_worker {} {
    variable router
    variable pending_secrets
    variable starting
    variable settings
    if {![info exists pending_secrets]} {return $router}
    if {$starting} {error "Worker initialization is already in progress"}
    set starting 1
    set config $settings
    try {
        ::telemetry::connect [dict get $config content_database] -secret_config [dict get $pending_secrets postgres]
        dict set config content_connection $::telemetry::connection
        init_worker $config -secret_config $pending_secrets
        unset pending_secrets
        return $router
    } on error {message options} {
        # A failed first event must not retain keys, sockets or a partial mount.
        if {$::accounts::mount ne {}} {catch {::web::user::release $::accounts::mount}}
        set ::accounts::mount {}; set ::accounts::store {}
        foreach package {tratelimit treqmon} {
            catch {::${package}::middleware::valkeystore::shutdown}
        }
        catch {::telemetry::close}
        dict unset config content_connection
        set settings $config
        return -options $options $message
    } finally {
        set starting 0
    }
}

# Attach the route name and invoke its handler.
proc ::site::invoke {handler name request context params} {
    dict set context route_name $name
    $handler $context $request
}

# Normalize the request and preserve package-owned response policies.
proc ::site::dispatch {router request {context {}}} {
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
