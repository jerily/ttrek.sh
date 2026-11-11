# Private tasks invoked directly through the Lambda Invoke API. API Gateway
# requests retain their HTTP envelope and cannot select this dispatch path.
namespace eval ::site_patch {}
proc ::site_patch::run {task context} {
    if {$task ni {task_initdb_website task_sync_website}} {error "Unknown patch task"}
    set completed {}
    foreach name [::site_patch::$task $context] {lappend completed [list S $name]}
    ::tjson::typed_to_json [list M [dict create ok {BOOL 1} task [list S $task] completed [list L $completed]]]
}

proc ::site_patch::task_initdb_website {context} {
    set initialized {}
    ::tpersist::db_transaction $::telemetry::connection {
        package require web-static-wiki 0.1.4
        package require web-static-blog 0.1.3
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
    set stores [::content_images::database_stores $::telemetry::connection [dict get $settings content_images]]
    # Both collections and registry metadata commit together. Immutable image
    # objects uploaded before a rollback are safe to reuse on retry.
    ::tpersist::db_transaction $::telemetry::connection {
        foreach {kind directory} {wiki docs blog blog} {
            ::web::static::${kind}::sync [dict get $stores $kind] [file join $root content $directory]
        }
        ::telemetry::sync_registry_metadata [dict get $settings registry_dir]
    }
    return {wiki blog registry}
}
