#
# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.
#

# Scheduled telemetry export/restore. Uses the existing PostgreSQL driver and
# AWS SDK; no external executables. HTTP requests cannot enter this handler.
namespace eval ::telemetry_maintenance {}

# Open the database connection used by this service.
proc ::telemetry_maintenance::connect {settings} {
    package require tdbc::postgres
    set options {}
    dict for {key value} $settings {
        if {$key ne "dialect"} {lappend options -$key $value}
    }
    if {[catch {::tdbc::postgres::connection new {*}$options} db]} {
        error "Could not connect for telemetry maintenance"
    }
    return $db
}

# Stop maintenance before exhausting the invocation deadline.
proc ::telemetry_maintenance::check_deadline {deadline} {
    if {[clock milliseconds] >= $deadline} {error "Telemetry maintenance time budget exceeded"}
}

# Export every application table in the current schema, including its live JSON
# schema. The maintenance connection keeps the advisory lock while this dedicated
# tpersist connection owns the consistent export snapshot.
proc ::telemetry_maintenance::backup {settings path deadline} {
    package require tpersist 0.1.5
    set startup {}
    if {[dict exists $settings options]} {set startup [dict get $settings options]}
    dict set settings options "$startup -c statement_timeout=20000 -c lock_timeout=5000 -c idle_in_transaction_session_timeout=60000"
    set options {-autobegin false}
    dict for {key value} $settings {lappend options -$key $value}
    set connection [::tpersist::db_connect {*}$options]
    try {
        # Bound database waits independently of the per-batch export deadline.
        # TDBC's PostgreSQL startup options preserve the selected search_path.
        return [::tpersist::db_export_jsonl $connection $path -gzip true \
            -deadline $deadline -max_bytes [expr {400 * 1024 * 1024}]]
    } finally {::tpersist::db_disconnect $connection}
}

# Upload the selected artifacts to the configured storage service.
proc ::telemetry_maintenance::upload {path bucket key} {
    package require awss3
    set client [::aws::s3::create [dict create region $::env(AWS_REGION)]]
    try {$client put $bucket $key $path} finally {$client destroy}
}

# Execute the selected maintenance operation with validated settings.
proc ::telemetry_maintenance::run {settings context} {
    if {[::app_config::mode] ne "PROD" || [dict get $settings dialect] ne "postgresql"} {
        error "Scheduled telemetry maintenance requires PROD PostgreSQL"
    }
    if {![info exists ::env(TELEMETRY_BACKUP_BUCKET)] || $::env(TELEMETRY_BACKUP_BUCKET) eq {}} {
        error "TELEMETRY_BACKUP_BUCKET is required"
    }
    set deadline [expr {[dict get $context lambda-runtime-deadline-ms] - 30000}]
    set db {}
    set path {}
    set phase connect
    try {
        set db [connect $settings]
        $db allrows {SET statement_timeout = '20s'}
        $db allrows {SET lock_timeout = '5s'}
        $db allrows {SET idle_in_transaction_session_timeout = '60s'}
        set locked [dict get [lindex [$db allrows {SELECT pg_try_advisory_lock(208894771, 1) AS locked}] 0] locked]
        if {$locked ni {1 t true}} {return {status skipped reason already-running}}
        set channel [file tempfile path /tmp/ttrek-telemetry-XXXXXX]
        close $channel
        set phase backup
        backup $settings $path $deadline
        check_deadline $deadline
        set id [dict get $context lambda-runtime-aws-request-id]
        if {![regexp {^[A-Za-z0-9-]+$} $id]} {error "Invalid invocation ID"}
        set key telemetry/backups/[clock format [clock seconds] -gmt true -format %Y/%m/%d/%Y%m%dT%H%M%SZ]-$id.jsonl.gz
        set phase upload
        upload $path $::env(TELEMETRY_BACKUP_BUCKET) $key
        set finish [expr {[dict get $context lambda-runtime-deadline-ms] - 5000}]
        check_deadline $finish
        set phase vacuum
        # Outside the snapshot transaction. Autovacuum remains enabled as well.
        set timeout [expr {max(1, min(20000, $finish - [clock milliseconds]))}]
        $db allrows "SET statement_timeout = $timeout"
        $db allrows {VACUUM (ANALYZE)}
        puts "Telemetry backup and vacuum completed: s3://$::env(TELEMETRY_BACKUP_BUCKET)/$key"
        return [dict create status completed key $key]
    } on error {message options} {
        # Never propagate connection arguments, data rows or driver diagnostics.
        return -code error -errorcode [list TELEMETRY MAINTENANCE $phase] "Telemetry maintenance failed during $phase"
    } finally {
        if {$db ne {}} {catch {$db close}}
        if {$path ne {}} {file delete -force $path}
    }
}

# Restore only into an empty telemetry schema, created by telemetry::initdb.
# All inserts use tpersist compilation and bound TDBC parameters. A missing
# footer, bad count, invalid row or damaged gzip rolls the entire restore back.
proc ::telemetry_maintenance::restore {db path} {
    set definitions [::telemetry::table_definitions]
    set channel [open $path rb]
    zlib push gunzip $channel
    fconfigure $channel -encoding utf-8 -translation lf
    try {
        $db begintransaction
        # Serialize with publishers; invalidation commits only with a valid restore.
        $db allrows {SELECT id FROM registry_search_snapshot WHERE id = 1 FOR UPDATE}
        set header [::tjson::json_to_simple [gets $channel]]
        if {[dict get $header format] ne "ttrek-telemetry" || [dict get $header version] ne "1" ||
            [dict get $header tables] ne [dict keys $definitions]} {error "Unsupported telemetry backup"}
        set counts {}
        dict for {table definition} $definitions {
            # Names come exclusively from the application's schema definitions.
            if {[dict get [lindex [$db allrows "SELECT COUNT(*) AS n FROM \"$table\""] 0] n]} {
                error "Restore requires empty telemetry tables"
            }
            dict set counts $table 0
        }
        set complete false
        while {[gets $channel line] >= 0} {
            set record [::tjson::json_to_simple $line]
            if {[dict exists $record complete]} {
                if {![dict get $record complete] || [dict get $record counts] ne $counts || [gets $channel line] >= 0} {
                    error "Invalid telemetry backup footer"
                }
                set complete true
                break
            }
            set table [dict get $record table]
            set columns [dict get $definitions $table columns]
            set row [dict get $record values]
            # Version 1 backups predating registry metadata omitted these fields.
            if {$table eq "packages"} {
                foreach {field default} {description {} url {} license {} tags {[]} languages {[]} listed 0 recipe {{}} patches {{}}} {
                    if {![dict exists $row $field]} {dict set row $field $default}
                }
            }
            if {[lsort [dict keys $row]] ne [lsort [dict keys $columns]]} {error "Invalid backup columns"}
            set values {}
            dict for {column spec} $columns {
                set value [dict get $row $column]
                set type [dict get $spec type]
                if {$type eq "binary"} {set value [binary decode base64 -strict $value]}
                dict set values $column [::tpersist::db_value $value -type $type]
            }
            set query [::tpersist::db_values [::tpersist::db_insert $table] $values -expressions]
            set compiled [::tpersist::db_compile $query -dialect postgresql]
            set statement [$db prepare [dict get $compiled sql]]
            try {
                dict for {name type} [dict get $compiled types] {
                    $statement paramtype $name [dict get {binary varbinary text varchar integer bigint bigint bigint} $type]
                }
                set result [$statement execute [dict get $compiled params]]
                $result close
            } finally {$statement close}
            dict incr counts $table
        }
        if {!$complete} {error "Incomplete telemetry backup"}
        # Read/close validates the compressed stream before committing rows.
        close $channel
        set channel {}
        dict for {table definition} $definitions {
            dict for {column spec} [dict get $definition columns] {
                if {[dict exists $spec auto_increment]} {
                    $db allrows "SELECT setval(pg_get_serial_sequence('$table', '$column'), COALESCE(MAX(\"$column\"), 1), MAX(\"$column\") IS NOT NULL) FROM \"$table\""
                }
            }
        }
        $db allrows {UPDATE registry_search_snapshot SET revision = '', fingerprint = '' WHERE id = 1}
        $db commit
        return $counts
    } on error {message options} {
        catch {$db rollback}
        return -options $options $message
    } finally {if {$channel ne {}} {close $channel}}
}
