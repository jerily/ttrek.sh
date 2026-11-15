#
# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.
#

package require tjson
package require trequests 1.1.0
namespace eval ::local_patch {}

# Attach the route name and invoke its handler.
proc ::local_patch::invoke {task port function} {
    if {$task ni {task_initdb_website task_sync_website task_publish_search task_prune_accounts task_sync_access task_refresh_package_tracker}} {error "Unknown patch task"}
    if {![string is integer -strict $port] || $port < 1 || $port > 65535} {error "Invalid Lambda port"}
    if {![regexp {^[A-Za-z0-9_-]+$} $function]} {error "Invalid Lambda function name"}
    set payload [::tjson::typed_to_json [list M [dict create source {S ttrek.patch} task [list S $task]]]]
    set url http://127.0.0.1:$port/2015-03-31/functions/$function/invocations
    set response [::trequests::request POST $url -data_binary [encoding convertto utf-8 $payload] \
        -content_type application/json -timeout 320000 -timeout_connect 3000]
    try {
        if {[$response status_code] != 200} {error "Local Lambda invocation failed (HTTP [$response status_code]): [$response error]"}
        foreach {key value} [$response headers] {
            if {[string equal -nocase $key x-amz-function-error]} {error "Local Lambda task failed: [$response content]"}
        }
        set body [encoding convertfrom utf-8 [$response content]]
        set result [::tjson::json_to_simple $body]
        if {![dict exists $result ok] || ![string is boolean -strict [dict get $result ok]] ||
            ![dict get $result ok] || ![dict exists $result task] || [dict get $result task] ne $task} {
            error "Local Lambda did not confirm task completion"
        }
        return $body
    } finally {$response destroy}
}

# Run this command-line entry point with validated arguments.
proc ::local_patch::main {root arguments} {
    if {![llength $arguments] || "--help" in $arguments || "-h" in $arguments} {
        return "Usage: invoke-patch-local.sh bootstrap-local|task_initdb_website|task_sync_website|task_publish_search|task_prune_accounts|task_sync_access|task_refresh_package_tracker ?--lambda-port PORT?"
    }
    set task [lindex $arguments 0]
    set options [lrange $arguments 1 end]
    set port 3001
    if {[info exists ::env(TTREK_LAMBDA_PORT)]} {set port $::env(TTREK_LAMBDA_PORT)}
    if {[llength $options]} {
        if {[llength $options] != 2 || [lindex $options 0] ne "--lambda-port"} {error "Expected --lambda-port PORT"}
        set port [lindex $options 1]
    }
    set channel [open [file join $root etc lambda.json] r]
    try {set settings [::tjson::json_to_simple [read $channel]]} finally {close $channel}
    set tasks [list $task]
    if {$task eq "bootstrap-local"} {
        set tasks {task_initdb_website task_sync_access task_sync_website task_refresh_package_tracker}
    }
    set results {}
    foreach selected $tasks {
        # Each invocation validates completion before the next task can start.
        lappend results [invoke $selected $port [dict get $settings function]]
    }
    return [join $results \n]
}

if {[file normalize [info script]] eq [file normalize $argv0]} {
    set root [file dirname [file dirname [file normalize [info script]]]]
    if {[catch {::local_patch::main $root $argv} result]} {
        puts stderr "Local patch failed: $result"
        exit 1
    }
    puts $result
}
