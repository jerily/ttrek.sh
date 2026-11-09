package require Tcl 9.1
package require twebserver
package require tjson
package require thread
package require tratelimit 1.0.1
package require treqmon 2.1.0
package require web-static-wiki 0.1.0
package require web-static-blog 0.1.0
package require tpathexp 1.1.0

namespace eval ::site {
    variable settings
    variable router
}

foreach module {assets responses templates releases request-validation search handlers} {
    uplevel #0 [list source [file join [file dirname [info script]] $module.tcl]]
}

proc ::site::config {} {variable settings; return $settings}
proc ::site::root {} {dict get [config] rootdir}

proc ::site::configure {config} {
    variable settings $config
    ::views::init [file join [root] www]
    ::recipe_search::load [file join [root] etc search-index.json]
    if {[dict exists $settings tratelimit]} {
        ::tratelimit::init_middleware [dict get $settings tratelimit]
    }
    if {[dict exists $settings treqmon]} {
        ::treqmon::init_middleware [dict get $settings treqmon]
    }
}

# Each worker owns a router and immutable directory snapshots.
proc ::site::mount {router} {
    set templates $::views::templates
    foreach {kind title prefix} {wiki Documentation /docs blog Blog /blog} {
        set directory [expr {$kind eq "wiki" ? "docs" : "blog"}]
        set store [::web::static::${kind}::create -directory [file join [root] content $directory] -title $title]
        ::web::static::${kind}::mount $router -store $store -prefix $prefix \
            -config [dict create master_template [dict get $templates ${directory}-master.html.jinja] \
                templates [dict create master.html.jinja [dict get $templates master.html.jinja]]]
    }
    set monitor_master request-monitor-master.html.jinja
    if {[dict exists [config] request_monitor master_template]} {
        set monitor_master [dict get [config] request_monitor master_template]
    }
    ::treqmon::mount $router -prefix /request-monitor \
        -include_active_users [expr {![catch {package present tsession}]}] \
        -config [dict create master_template [dict get $templates $monitor_master] \
            templates [dict create master.html.jinja [dict get $templates master.html.jinja]] \
            chart_script [::assets::url /js/chart.umd.js]]
    foreach {method pattern handler name} [source [file join [root] tcl routes.tcl]] {
        $router add $method $pattern [list ::site::invoke $handler $name] -strict true
    }
}

proc ::site::init_worker {settings} {
    variable router
    configure $settings
    set router [::tpathexp::router]
    mount $router
}

proc ::site::invoke {handler name request context params} {
    dict set context route_name $name
    $handler $context $request
}

proc ::site::dispatch {router request {context {}}} {
    variable settings
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
    if {[dict exists $settings treqmon]} {
        set request [::treqmon::middleware::enter $context $request]
    }
    if {[dict exists $settings tratelimit]} {
        if {[catch {::tratelimit::middleware::enter $context $request} result options]} {
            if {[dict exists $options statusCode]} {return $options}
            return -options $options $result
        }
        set request $result
    }
    # Render HEAD as GET so compression and validators select identical headers.
    set routed_request $request
    if {[dict get $request method] eq "HEAD"} {
        dict set routed_request method GET
        dict set routed_request httpMethod GET
    }
    set response [$router dispatch $routed_request $context]
    set content_type {}
    set has_policy 0
    dict for {name value} [dict get $response headers] {
        if {[string equal -nocase $name Content-Type]} {set content_type $value}
        if {[string equal -nocase $name Cache-Control]} {set has_policy 1}
    }
    if {[string match {text/html*} $content_type]} {
        dict set response body [::views::stamp_year [dict get $response body]]
        # Keep package-owned no-store policies; ordinary site HTML revalidates
        # so a deployment promptly switches browsers to the new asset URLs.
        if {!$has_policy} {dict set response headers Cache-Control no-cache}
    }
    if {[dict exists $settings treqmon]} {
        set response [::treqmon::middleware::leave $context $request $response]
    }
    return [::responses::prepare $request $response]
}

proc ::site::process_conn {context request} {
    variable router
    if {[catch {dispatch $router $request $context} response options]} {
        puts stderr [dict get $options -errorinfo]
        set response [::twebserver::build_response 500 text/plain {Unable to serve this request.}]
    }
    ::twebserver::return_response [dict get $context conn] $response
}
