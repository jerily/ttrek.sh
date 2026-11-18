# SPDX-License-Identifier: MIT
# Request-scoped execution traces, enabled by default. Never retain command arguments,
# results, SQL, paths, cookies, or credentials in the profile.
namespace eval ::site_profile {
    variable active false
    variable sequence 0
    variable targets {
        ::site::dispatch_request dispatch
        ::site::invoke handler
        ::site::package_dispatch handler
        ::site::middleware_enter middleware_init
        ::treqmon::middleware::enter monitor_enter
        ::treqmon::middleware::leave monitor_leave
        ::accounts::monitor_enter authentication
        ::accounts::monitor_authorize authorization
        ::tratelimit::middleware::enter rate_limit
        ::tratelimit::middleware::enter_route route_rate_limit
        ::site::sensitive_enter sensitive_route
        ::site::service service
        ::site::database database
        ::tpersist::db_connect sql_connect
        ::tpersist::db_execute sql_execute
        ::tpersist::db_foreach_row sql_foreach
        ::tpersist::_raw sql_raw
        ::telemetry::registry_catalog catalog_read
        ::recipe_search::catalog_entries catalog_group
        ::recipe_search::cards catalog_cards
        ::package_tracker::view tracker
        ::package_tracker::cache tracker_cache
        ::homepage::data homepage
        ::views::render template
        ::views::render_package template
        ::accounts::navigation navigation
        ::responses::prepare response_prepare
        ::tjson::json_to_simple json_decode
        ::tjson::typed_to_json json_encode
        ::treqmon::middleware::valkeystore::register_datapoint monitor_store
        ::treqmon::middleware::valkeystore::register_recent_request monitor_recent
        ::tratelimit::middleware::valkeystore::consume rate_limit_store
        ::package package
        ::source source
    }
}

proc ::site_profile::begin {context} {
    variable active
    if {$active || ([info exists ::env(TTREK_PROFILE)] && $::env(TTREK_PROFILE) ne "1")} {return false}
    variable sequence
    incr sequence
    variable started [clock clicks -microseconds]
    variable stack {}
    variable metrics {}
    variable installed {}
    variable route unmatched
    variable status 0
    variable request_id {}
    if {[dict exists $context lambda-runtime-aws-request-id]} {
        set request_id [dict get $context lambda-runtime-aws-request-id]
    }
    set active true
    refresh
    return true
}

# Packages and sourced modules can introduce targets during the first request.
# Tracing the commands themselves preserves callers' stack/upvar semantics.
proc ::site_profile::refresh {} {
    variable targets
    variable installed
    foreach {command label} $targets {
        if {[dict exists $installed $command] || ![llength [info commands $command]]} continue
        set callback [list ::site_profile::observe $label]
        trace add execution $command {enter leave} $callback
        dict set installed $command $callback
    }
}

proc ::site_profile::observe {label command args} {
    # Only package require performs loading; package provide/ifneeded are noisy.
    if {$label eq "package" && [lindex $command 1] ne "require"} {return}
    variable stack
    variable metrics
    set now [clock clicks -microseconds]
    if {[lindex $args end] eq "enter"} {
        if {$label eq "handler"} {
            variable route
            # Only static handler names; never route captures or request paths.
            if {[lindex $command 0] eq "::site::invoke"} {
                set route [lindex $command 2]
            } else {
                set route [lindex [lindex $command 2] 0]
            }
        }
        lappend stack [list $label $now 0]
        return
    }
    lassign [lindex $stack end] name start children
    set stack [lrange $stack 0 end-1]
    set elapsed [expr {$now - $start}]
    if {![dict exists $metrics $name]} {dict set metrics $name {calls 0 total_us 0 self_us 0}}
    set metric [dict get $metrics $name]
    dict incr metric calls
    dict incr metric total_us $elapsed
    dict incr metric self_us [expr {$elapsed - $children}]
    dict set metrics $name $metric
    if {[llength $stack]} {
        lassign [lindex $stack end] parent start children
        lset stack end [list $parent $start [expr {$children + $elapsed}]]
    }
    if {$label eq "dispatch" && [lindex $args 0] == 0} {
        variable status
        set status [dict get [lindex $args 1] statusCode]
    }
    if {$label in {package source}} {refresh}
}

proc ::site_profile::finish {code} {
    variable started
    set elapsed [expr {([clock clicks -microseconds] - $started) / 1000.0}]
    variable installed
    variable active
    dict for {command callback} $installed {
        catch {trace remove execution $command {enter leave} $callback}
    }
    set active false
    # Profiling output must never turn an otherwise successful request into an error.
    catch {emit $elapsed $code}
}

proc ::site_profile::emit {elapsed code} {
    variable metrics
    variable sequence
    variable route
    variable status
    variable request_id
    set fields [dict create event {S site_profile} request_id [list S $request_id] \
        sequence [list N $sequence] first_request [list BOOL [expr {$sequence == 1}]] \
        route [list S $route] status [list N $status] completion_code [list N $code] \
        duration_ms [list N [format %.3f $elapsed]]]
    foreach {key environment} {memory_mb AWS_LAMBDA_FUNCTION_MEMORY_SIZE version AWS_LAMBDA_FUNCTION_VERSION} {
        if {[info exists ::env($environment)]} {dict set fields $key [list S $::env($environment)]}
    }
    if {[info exists ::site::settings] && [dict exists $::site::settings loading]} {
        dict set fields loading [list S [dict get $::site::settings loading]]
    }
    set values {}
    dict for {label metric} $metrics {
        dict set values $label [list M [dict create calls [list N [dict get $metric calls]] \
            total_ms [list N [format %.3f [expr {[dict get $metric total_us] / 1000.0}]]] \
            self_ms [list N [format %.3f [expr {[dict get $metric self_us] / 1000.0}]]]]]
    }
    dict set fields timings [list M $values]
    puts stderr [::tjson::typed_to_json [list M $fields]]
}
