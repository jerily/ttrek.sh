# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.

# Private tasks invoked directly through the Lambda Invoke API. API Gateway
# requests retain their HTTP envelope and cannot select this dispatch path.
namespace eval ::site_patch {}
proc ::site_patch::run {task context} {
    if {$task ni {task_initdb_website task_sync_website task_publish_search}} {error "Unknown patch task"}
    set completed {}
    foreach name [::site_patch::$task $context] {lappend completed [list S $name]}
    ::tjson::typed_to_json [list M [dict create ok {BOOL 1} task [list S $task] completed [list L $completed]]]
}

# Schema providers must preserve existing tables and rows on every invocation.
# Importing or replacing website content belongs only to task_sync_website.
proc ::site_patch::task_initdb_website {context} {
    set initialized {}
    ::tpersist::db_transaction $::telemetry::connection {
        package require web-static-wiki 0.1.7
        package require web-static-blog 0.1.6
        ::telemetry::initdb
        lappend initialized ::telemetry::initdb
        set dialect [::tpersist::db_dialect $::telemetry::connection]
        # Requiring tpersist during connection setup indexes the runtime's
        # installed Tcl packages. Explicit providers avoid invoking unrelated
        # development tools with separate databases.
        foreach {package command backend} {
            web-static-wiki    ::web::static::wiki::initdb    any
            web-static-blog    ::web::static::blog::initdb    any
            tsession::sql      ::tsession::sql::initdb      any
            tsession-sqlite    ::tsession::sqlite::initdb   sqlite
            tsession-postgres  ::tsession::postgres::initdb postgresql
            web-user           ::web::user::initdb           any
            web-forum          ::web::forum::initdb          any
            web-wiki           ::web::wiki::initdb           any
            web-blog           ::web::blog::initdb           any
        } {
            if {![llength [package versions $package]] || $backend ni [list any $dialect]} continue
            # An installed but broken provider must fail the task, not be skipped.
            package require $package
            set args [list $::telemetry::connection]
            if {$package eq "tsession::sql"} {lappend args $dialect}
            $command {*}$args
            lappend initialized $command
        }
    }
    return $initialized
}

proc ::site_patch::task_sync_website {context} {
    set settings [::site::config]
    set root [dict get $settings rootdir]
    set registry [file join $root registry]
    if {![file isdirectory $registry] || ![llength [glob -nocomplain -directory $registry -types f */*/ttrek.json]]} {
        error "The deployed package has no registry snapshot; rebuild the Lambda ZIP before syncing"
    }
    set stores [::content_images::database_stores $::telemetry::connection [dict get $settings content_images]]
    # Both collections and the complete registry commit together. Image updates
    # in S3 are independent of this transaction and are not rolled back with SQL.
    ::telemetry::transaction {
        ::telemetry::lock_search_snapshot
        foreach {kind directory} {wiki docs blog blog} {
            ::web::static::${kind}::sync [dict get $stores $kind] [file join $root content $directory]
        }
        ::telemetry::sync_registry_metadata $registry
        ::telemetry::publish_search_snapshot
    }
    return {wiki blog registry}
}

# Publish database edits or restored metadata without reimporting recipe files.
proc ::site_patch::task_publish_search {context} {
    ::telemetry::publish_search_snapshot true
    return {search}
}
