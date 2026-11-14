# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.

# Derived data is deliberately outside telemetry::table_definitions and backups.
namespace eval ::telemetry {variable search_module [file join [file dirname [info script]] search-snapshot.tcl]}

# Apply the derived schema and ensure its singleton row.
proc ::telemetry::init_search_snapshot {} {
    variable connection
    variable schema_dir
    db_apply_schema $connection [file join $schema_dir search-snapshot.json] -additive true
    set defaults [dict create format [db_value 3 -type integer]]
    foreach field {revision fingerprint mapping} {dict set defaults $field [db_value {} -type text]}
    foreach field {names descriptions} {dict set defaults $field [db_value [binary format a0 {}] -type binary]}
    ensure_row registry_search_snapshot id [dict create id [db_value 1 -type integer]] $defaults
}

# Acquire before reading or changing the catalog. PostgreSQL locks the singleton
# row; SQLite's first write reserves the writer lock before any catalog read.
proc ::telemetry::lock_search_snapshot {} {
    variable connection
    variable dialect
    if {$dialect eq "postgresql"} {
        set found [::tpersist::_raw $connection {SELECT id FROM registry_search_snapshot WHERE id = 1 FOR UPDATE}]
    } else {
        ::tpersist::_raw $connection {UPDATE registry_search_snapshot SET id = id WHERE id = 1}
        set found [::tpersist::_raw $connection {SELECT id FROM registry_search_snapshot WHERE id = 1}]
    }
    if {![llength $found]} {error "Search snapshot schema is not initialized"}
}

proc ::telemetry::search_snapshot_revision {} {
    set rows [rows [db_where [db_select registry_search_snapshot -columns revision] [db_eq [db_col id] [db_value 1 -type integer]]]]
    if {![llength $rows]} {return {}}
    dict get [lindex $rows 0] revision
}

proc ::telemetry::search_snapshot {} {
    set rows [rows [db_where [db_select registry_search_snapshot] [db_eq [db_col id] [db_value 1 -type integer]]]]
    if {![llength $rows] || [dict get [lindex $rows 0] revision] eq {}} {error "Search snapshot has not been published"}
    return [lindex $rows 0]
}

# Validate the revision and read metadata from one database snapshot. Readers can
# continue serving the committed generation while a publisher prepares the next.
proc ::telemetry::search_result_metadata {revision names} {
    variable connection
    variable dialect
    transaction {
        if {$dialect eq "postgresql"} {
            ::tpersist::_raw $connection {SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY}
        }
        set found [::tpersist::_raw $connection {SELECT revision FROM registry_search_snapshot WHERE id = 1}]
        if {![llength $found] || [dict get [lindex $found 0] revision] ne $revision} {
            return -code error -errorcode {SEARCH REVISION} "Search revision changed"
        }
        set result {}
        # Stay below older SQLite parameter limits even for broad searches.
        for {set offset 0} {$offset < [llength $names]} {incr offset 500} {
            lappend result {*}[registry_catalog [lrange $names $offset [expr {$offset + 499}]]]
        }
        return $result
    }
}

# Rebuild from stored metadata only. Callers can nest this in the catalog sync
# transaction; failures then roll back both the catalog and its new snapshot.
proc ::telemetry::publish_search_snapshot {{force false}} {
    variable connection
    variable search_module
    if {![llength [info commands ::recipe_search::build_snapshot]]} {source $search_module}
    transaction {
        lock_search_snapshot
        set inputs [::recipe_search::snapshot_inputs [registry_catalog]]
        set fingerprint [dict get $inputs fingerprint]
        set current [lindex [rows [db_where [db_select registry_search_snapshot -columns {fingerprint revision}] [db_eq [db_col id] [db_value 1 -type integer]]]] 0]
        if {!$force && [dict get $current fingerprint] eq $fingerprint && [dict get $current revision] ne {}} {
            return [dict get $current revision]
        }
        set snapshot [::recipe_search::build_snapshot $inputs]
        set values {}
        dict for {field value} $snapshot {
            set type [expr {$field in {names descriptions} ? "binary" : ($field eq "format" ? "integer" : "text")}]
            dict set values $field [db_value $value -type $type]
        }
        db_execute $connection [db_where [db_values [db_update registry_search_snapshot] $values -expressions] [db_eq [db_col id] [db_value 1 -type integer]]]
        return [dict get $snapshot revision]
    }
}
