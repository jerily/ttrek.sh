package require Tcl 9.1
package require twebserver
package require tjson
package require thread
package require tratelimit 1.0.1
package require treqmon 2.0.0
package require web-wiki 0.1.0
package require tpathexp 1.1.0

namespace eval ::site {
    variable settings
    variable router
    variable connection
}

foreach module {templates request-monitor releases request-validation search handlers} {
    uplevel #0 [list source [file join [file dirname [info script]] $module.tcl]]
}

proc ::site::config {} {variable settings; return $settings}
proc ::site::root {} {dict get [config] rootdir}

proc ::site::configure {config} {
    variable settings $config
    ::views::init [file join [root] www]
    ::recipe_search::init [dict get $settings registry_dir]
    if {[dict exists $settings tratelimit]} {
        ::tratelimit::init_middleware [dict get $settings tratelimit]
    }
    if {[dict exists $settings treqmon]} {
        ::treqmon::init_middleware [dict get $settings treqmon]
    }
}

# The host owns the connection and router; the wiki owns schema and content.
proc ::site::initdb {connection} {::web::wiki::initdb $connection}

proc ::site::sync {connection directory} {
    set store [::web::wiki::create -connection $connection -domain ttrek.sh -title Documentation]
    ::web::wiki::sync $store $directory
}

proc ::site::mount {router connection} {
    set store [::web::wiki::create -connection $connection -domain ttrek.sh -title Documentation]
    set templates $::views::templates
    ::web::wiki::mount $router -store $store -prefix /docs \
        -navigation {{Home /} {Documentation /docs} {Packages /packages}} \
        -config [dict create master_template [dict get $templates docs-master.html.jinja] \
            templates [dict create master.html.jinja [dict get $templates master.html.jinja]]]
    foreach {method pattern handler name} [source [file join [root] tcl routes.tcl]] {
        $router add $method $pattern [list ::site::invoke $handler $name] -strict true
    }
}

proc ::site::init_worker {settings} {
    variable connection
    variable router
    set database [dict get $settings docs_database]
    if {![file isfile $database]} {
        error "Documentation database is missing; run ttrek run -script init-docs first"
    }
    configure $settings
    set connection [::tpersist::db_connect -database $database -autobegin 0 -timeout 5000]
    set router [::tpathexp::router]
    mount $router $connection
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
    set response [$router dispatch $request $context]
    if {[dict exists $settings treqmon]} {
        set response [::treqmon::middleware::leave $context $request $response]
    }
    return $response
}

proc ::site::process_conn {context request} {
    variable router
    if {[catch {dispatch $router $request $context} response options]} {
        puts stderr [dict get $options -errorinfo]
        set response [::twebserver::build_response 500 text/plain {Unable to serve this request.}]
    }
    ::twebserver::return_response [dict get $context conn] $response
}
