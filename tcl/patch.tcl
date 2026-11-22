# 
# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.
# 

# Private tasks invoked directly through the Lambda Invoke API. API Gateway
# requests retain their HTTP envelope and cannot select this dispatch path.
namespace eval ::site_patch {}
# Execute the selected maintenance operation with validated settings.
proc ::site_patch::run {task context} {
    if {$task ni {task_initdb_website task_sync_website task_publish_search task_prune_accounts task_sync_access task_migrate_user_ids task_refresh_package_tracker task_backup_website task_process_email_queue}} {error "Unknown patch task"}
    set started [clock clicks -milliseconds]
    set status error
    log patch_task_start $task
    try {
        switch -- $task {
            task_process_email_queue {}
            task_prune_accounts - task_sync_access - task_migrate_user_ids {::accounts::ensure}
            task_backup_website {
                if {![llength [info commands ::telemetry_maintenance::run]]} {
                    source [file join [::site::root] tcl telemetry-maintenance.tcl]
                }
            }
            default {::site::database}
        }
        set completed {}
        foreach name [::site_patch::$task $context] {lappend completed [list S $name]}
        set result [::tjson::typed_to_json [list M [dict create ok {BOOL 1} task [list S $task] completed [list L $completed]]]]
        set status ok
        return $result
    } finally {
        log patch_task_end $task $status [expr {[clock clicks -milliseconds] - $started}]
    }
}

# Log lifecycle metadata only; task errors can contain credentials or row data.
proc ::site_patch::log {event task {status {}} {elapsed 0}} {
    set fields [dict create event [list S $event] task [list S $task] \
        timestamp [list S [clock format [clock seconds] -format {%Y-%m-%dT%H:%M:%SZ} -gmt true]]]
    if {$status ne {}} {
        dict set fields status [list S $status]
        dict set fields duration_ms [list N $elapsed]
    }
    puts stderr [::tjson::typed_to_json [list M $fields]]
}

# Schema providers must preserve existing tables and rows on every invocation.
# Account data migrations are invoked separately from schema initialization.
# Importing or replacing website content belongs only to task_sync_website.
proc ::site_patch::task_initdb_website {context} {
    set initialized {}
    ::tpersist::db_transaction $::telemetry::connection {
        package require web-static-wiki 0.1.7
        package require web-static-blog 0.1.6
        ::telemetry::initdb
        lappend initialized ::telemetry::initdb
        # Requiring tpersist during connection setup indexes the runtime's
        # installed Tcl packages. Explicit providers avoid invoking unrelated
        # development tools with separate databases.
        foreach {package command} {
            web-static-wiki ::web::static::wiki::initdb
            web-static-blog ::web::static::blog::initdb
            web-user        ::web::user::initdb
            web-forum       ::web::forum::initdb
            web-wiki        ::web::wiki::initdb
            web-blog        ::web::blog::initdb
        } {
            if {![llength [package versions $package]]} continue
            # An installed but broken provider must fail the task, not be skipped.
            package require $package
            set args [list $::telemetry::connection]
            if {$package eq "web-user"} {
                set policy [dict get [::site::config] account policy]
                ::app_config::load_session_backend $policy
                lappend args $policy
            }
            $command {*}$args
            lappend initialized $command
        }
    }
    return $initialized
}

# Import website content and registry metadata in one transaction.
proc ::site_patch::task_sync_website {context} {
    set settings [::site::config]
    set root [dict get $settings rootdir]
    set images [dict get $settings content_images]
    set production [expr {[::app_config::mode] eq "PROD"}]
    set stores [::content_images::database_stores $::telemetry::connection $images]
    package require tgit2 0.1.0
    set registry [file tempdir]
    try {
        ::tgit2::clone -depth 1 https://github.com/jerily/ttrek-registry.git $registry
        if {![llength [glob -nocomplain -directory $registry -types f */*/ttrek.json]]} {
            error "The public registry contains no recipes"
        }
        ::telemetry::transaction {
            ::telemetry::lock_search_snapshot
            if {$production} {set collections [::content_images::archive_items $root $images]}
            foreach {kind directory} {wiki docs blog blog} {
                if {$production} {
                    ::web::static::${kind}::sync_prepared [dict get $stores $kind] [dict get $collections $kind]
                } else {
                    # LOCAL retains package sync for its disposable S3 mock.
                    ::web::static::${kind}::sync [dict get $stores $kind] [file join $root content $directory]
                }
            }
            ::telemetry::sync_registry_metadata $registry
            ::telemetry::publish_search_snapshot
        }
    } finally {
        file delete -force $registry
    }
    return {wiki blog registry}
}

# Publish database edits or restored metadata without reimporting recipe files.
proc ::site_patch::task_publish_search {context} {
    ::telemetry::publish_search_snapshot true
    return {search}
}

# Expose bounded account maintenance only through the private task dispatcher.
proc ::site_patch::task_prune_accounts {context} {
    set counts [::accounts::prune]
    set result {}
    dict for {name count} $counts {lappend result "$name:$count"}
    return $result
}

# Bounded draining also runs on its own schedule, so retries do not depend on
# another registration. Failed messages stay queued until visibility expires.
proc ::site_patch::task_process_email_queue {context} {
    set settings [::site::config]
    if {![dict exists $settings account display]} {return {}}
    set config [dict get $settings account display]
    if {![dict get $config email_enabled] || ![dict get $config email_queue_enabled]} {return {}}
    package require pure-tcl-aws-sqs 1.0.0
    package require pure-tcl-aws-ses 1.0.0
    set deadline [expr {[clock milliseconds] + 240000}]
    if {[dict exists $context lambda-runtime-deadline-ms]} {
        set runtimeEnd [dict get $context lambda-runtime-deadline-ms]
        set reserve [expr {min(30000, max(1000, ($runtimeEnd - [clock milliseconds]) / 4))}]
        set deadline [expr {min($deadline, $runtimeEnd - $reserve)}]
    }
    set sqs [::aws::sqs::create [dict create region [dict get $config email_region]]]
    set ses {}
    set sent 0
    set expired 0
    set failed 0
    try {
        set queue [dict get $config email_queue_url]
        for {set batch 0} {$batch < 10 && [clock milliseconds] < $deadline} {incr batch} {
            set messages [$sqs receive_messages $queue 10]
            if {![llength $messages]} {break}
            foreach message $messages {
                if {[clock milliseconds] >= $deadline} {break}
                if {[catch {
                    set body [::tjson::json_to_simple [dict get $message Body]]
                    set expires [dict get $body expires_at]
                    if {[dict get $body version] ne "1" || ![string is entier -strict $expires] || $expires < 0} {
                        error "Invalid queued email"
                    }
                    if {$expires && $expires <= [clock seconds]} {
                        incr expired
                    } else {
                        if {$ses eq {}} {set ses [::aws::ses::create [dict create region [dict get $config email_region]]]}
                        $ses send_email [dict get $body message]
                        incr sent
                    }
                    # Acknowledge only a successful send or an expired code.
                    $sqs delete_message $queue [dict get $message ReceiptHandle]
                }]} {incr failed}
            }
        }
    } finally {
        try {if {$ses ne {}} {$ses destroy}} finally {$sqs destroy}
    }
    # Do not expose message bodies, recipients, codes, or SDK errors in logs.
    if {$failed} {error "Queued email delivery failed for $failed message(s)"}
    return [list sent:$sent expired:$expired]
}

proc ::site_patch::task_sync_access {context} {
    set counts [::accounts::sync_access]
    set result {}
    dict for {name count} $counts {lappend result "$name:$count"}
    return $result
}

proc ::site_patch::task_migrate_user_ids {context} {
    set result {}
    dict for {name count} [::accounts::migrate_user_ids] {lappend result "$name:$count"}
    return $result
}

# Aggregation is only reachable through the IAM-authorized private task path.
proc ::site_patch::task_refresh_package_tracker {context} {
    list [::package_tracker::refresh]
}

# Reuse the production backup, upload and vacuum with patch lifecycle logging.
proc ::site_patch::task_backup_website {context} {
    set result [::telemetry_maintenance::run $::site_lambda::maintenanceSettings $context -secret_config $::site_lambda::maintenanceSecrets]
    set completed {}
    dict for {name value} $result {lappend completed "$name:$value"}
    return $completed
}
