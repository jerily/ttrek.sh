# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2024 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.

# Drivers are loaded by tpersist only when the selected backend connects.
package require tpersist

namespace eval ::telemetry {
    namespace import ::tpersist::db_*
    variable connection {}
    variable dialect {}
    variable event_list {
        register_environment  {-env -description}
        req_dist_get          {-env -os -arch}
        req_pkg_get           {-env -pkg_name}
        req_pkg_version_get   {-env -pkg_name -pkg_version}
        req_pkg_install_event {-env -pkg_name -pkg_version -install_outcome -install_is_toplevel -os -arch}
        req_reg_get_pkg_spec  {-env -pkg_name -pkg_version -os -arch}
        req_reg_get_pkg       {-env -pkg_name}
        req_logo_get          {-env}
    }

    variable known_os {
        {Linux}       {Linux}
        {Darwin}      {MacOS}
        {CYGWIN_NT-*} {Cygwin}
    }

    variable known_arch {
        aarch64 alpha arc arm arm64 i386 i486 i686 ia64
        m68k mips mips64 parisc ppc ppc64 ppc64le
        ppcle riscv64 s390 s390x sh sparc sparc64
        x86_64
    }

}

proc ::telemetry::init {settings} {
    variable connection
    variable dialect
    variable event_list
    close
    set dialect [dict get $settings dialect]
    dict for {name parameters} $event_list {
        dict set event_list $name [lsort $parameters]
    }
    set options {-autobegin false}
    dict for {key value} $settings {lappend options -$key $value}
    if {[catch {db_connect {*}$options} opened]} {
        # Driver diagnostics can contain connection options. Do not propagate
        # those details into Lambda logs or direct-server startup traces.
        return -code error -errorcode {TELEMETRY CONNECT} "Could not connect to the telemetry database"
    }
    set connection $opened
    try {
        transaction {create_schema} true
    } on error {message opts} {
        close
        return -options $opts $message
    }
}

# Retry an entire rolled-back transaction, never just its last statement.
# TDBC's SQLite adapter reports native lock failures without an SQLSTATE.
proc ::telemetry::transaction {script {schema false}} {
    variable connection
    variable dialect
    for {set attempt 0} {1} {incr attempt} {
        try {
            return [uplevel 1 [list ::tpersist::db_transaction $connection $script]]
        } on error {message opts} {
            set state [lindex [dict get $opts -errorcode] 2]
            set retry [expr {($dialect eq "sqlite" && $message in {"database is locked" "database table is locked"}) ||
                $state in {40001 40P01} || ($schema && $state in {23505 42P07 42710})}]
            if {!$retry || $attempt >= 4} {return -options $opts $message}
            after [expr {50 * ($attempt + 1)}]
        }
    }
}

proc ::telemetry::close {} {
    variable connection
    if {$connection ne {}} {
        db_disconnect $connection
        set connection {}
    }
}

proc ::telemetry::table_definitions {} {
    variable event_list
    set definitions {}
    set id {type integer primary_key 1 auto_increment 1}
    set required {type integer not_null 1}
    dict set definitions environments [db_define_table environments [dict create \
        env_id $id hash {type binary not_null 1} description {type text not_null 1} \
        last_seen {type bigint not_null 1}]]
    # Serialize registrations per hash without indexing descriptions, which
    # may be larger than PostgreSQL's B-tree index entry limit.
    dict set definitions environment_keys [db_define_table environment_keys [dict create \
        key_id $id hash {type binary unique 1 not_null 1} touched {type bigint not_null 1}]]
    dict set definitions package_names [db_define_table package_names [dict create \
        pkg_name_id $id name {type text unique 1 not_null 1}]]
    dict set definitions packages [db_define_table packages [dict create \
        pkg_id $id pkg_name_id $required version {type text not_null 1}] \
        -unique {{pkg_name_id version}} \
        -foreign_keys {{columns pkg_name_id table package_names referenced_columns pkg_name_id}}]
    dict set definitions platforms [db_define_table platforms [dict create \
        platform_id $id os {type text not_null 1} arch {type text not_null 1}] \
        -unique {{os arch}}]
    dict for {event parameters} $event_list {
        if {$event eq "register_environment"} continue
        set columns [dict create timestamp {type bigint not_null 1} env_id $required]
        set foreignKeys {{columns env_id table environments referenced_columns env_id}}
        if {"-pkg_version" in $parameters} {
            dict set columns pkg_id $required
            lappend foreignKeys {columns pkg_id table packages referenced_columns pkg_id}
        } elseif {"-pkg_name" in $parameters} {
            dict set columns pkg_name_id $required
            lappend foreignKeys {columns pkg_name_id table package_names referenced_columns pkg_name_id}
        }
        if {"-os" in $parameters} {
            dict set columns platform_id $required
            lappend foreignKeys {columns platform_id table platforms referenced_columns platform_id}
        }
        if {$event eq "req_pkg_install_event"} {
            dict set columns install_outcome $required
            dict set columns install_is_toplevel $required
        }
        dict set definitions $event [db_define_table $event $columns -foreign_keys $foreignKeys]
    }
    return $definitions
}

proc ::telemetry::create_schema {} {
    variable connection
    dict for {table definition} [table_definitions] {
        db_create_table $connection $definition -if_not_exists true
    }
    db_create_index $connection idx_environments_hash environments {hash} -if_not_exists true
    db_create_index $connection idx_install_package req_pkg_install_event {pkg_id platform_id} -if_not_exists true
}

proc ::telemetry::rows {statement} {
    variable connection
    dict get [db_execute $connection $statement] rows
}

# Resolve shared dimensions using unique constraints. A savepoint keeps a
# concurrent insert conflict from aborting the enclosing PostgreSQL transaction.
proc ::telemetry::ensure_row {table key values {extra {}}} {
    variable connection
    set query [db_select $table -columns [list $key]]
    dict for {column value} $values {
        set query [db_where $query [db_eq [db_col $column] $value]]
    }
    set found [rows $query]
    if {[llength $found]} {return [dict get [lindex $found 0] $key]}
    try {
        set found [db_transaction $connection {
            rows [db_returning [db_values [db_insert $table] [dict merge $values $extra] -expressions] $key]
        }]
    } on error {message opts} {
        if {[lindex [dict get $opts -errorcode] 2] ni {23000 23505}} {
            return -options $opts $message
        }
        set found [rows $query]
        if {![llength $found]} {return -options $opts $message}
    }
    return [dict get [lindex $found 0] $key]
}

proc ::telemetry::event {event_type args} {
    variable connection
    variable event_list
    variable known_arch
    variable known_os
    if {![dict exists $event_list $event_type]} {error "unknown telemetry event: $event_type"}
    if {[catch {dict size $args}] || [lsort [dict keys $args]] ne [dict get $event_list $event_type]} {
        error "wrong arguments for telemetry event: $event_type"
    }
    dict for {key value} $args {set [string range $key 1 end] $value}
    if {![regexp -nocase {^[0-9a-f]{64}$} $env]} {error "invalid telemetry environment ID"}
    set hash [db_value [binary decode hex $env] -type binary]
    set now [db_value [clock seconds] -type bigint]
    # Validate before writing any dimensions.
    if {[info exists os]} {
        if {$arch ni $known_arch} {error "unknown telemetry architecture: $arch"}
        set normalized {}
        dict for {pattern name} $known_os {
            if {[string match $pattern $os]} {set normalized $name; break}
        }
        if {$normalized eq {}} {error "unknown telemetry OS: $os"}
        set os $normalized
    }
    foreach key {install_outcome install_is_toplevel} {
        if {[info exists $key] && [set $key] ni {0 1}} {error "$key must be 0 or 1"}
    }
    transaction {
        if {$event_type eq "register_environment"} {
            set key_id [ensure_row environment_keys key_id [dict create hash $hash] [dict create touched $now]]
            db_execute $connection [db_where [db_values [db_update environment_keys] \
                [dict create touched $now] -expressions] [db_eq [db_col key_id] [db_value $key_id -type integer]]]
            set env_id [ensure_row environments env_id [dict create hash $hash \
                description [db_value $description -type text]] [dict create last_seen $now]]
            db_execute $connection [db_where [db_values [db_update environments] \
                [dict create last_seen $now] -expressions] [db_eq [db_col env_id] [db_value $env_id -type integer]]]
        } else {
            set query [db_where [db_select environments -columns env_id] [db_eq [db_col hash] $hash]]
            set found [rows [db_limit [db_order_by $query -expr {last_seen DESC, env_id DESC}] 1]]
            if {![llength $found]} {error "unknown telemetry environment: $env"}
            set values [dict create env_id [db_value [dict get [lindex $found 0] env_id] -type integer] timestamp $now]
            if {[info exists pkg_name]} {
                set pkg_name_id [ensure_row package_names pkg_name_id [dict create name [db_value $pkg_name -type text]]]
                if {[info exists pkg_version]} {
                    set pkg_id [ensure_row packages pkg_id [dict create \
                        pkg_name_id [db_value $pkg_name_id -type integer] version [db_value $pkg_version -type text]]]
                    dict set values pkg_id [db_value $pkg_id -type integer]
                } else {dict set values pkg_name_id [db_value $pkg_name_id -type integer]}
            }
            if {[info exists os]} {
                set platform_id [ensure_row platforms platform_id [dict create \
                    os [db_value $os -type text] arch [db_value $arch -type text]]]
                dict set values platform_id [db_value $platform_id -type integer]
            }
            foreach key {install_outcome install_is_toplevel} {
                if {[info exists $key]} {dict set values $key [db_value [set $key] -type integer]}
            }
            db_execute $connection [db_values [db_insert $event_type] $values -expressions]
        }
    }
    return
}

proc ::telemetry::stats {package_name {package_version {}}} {
    set query [db_select [db_table req_pkg_install_event -as ev] -expr {
        pl.os AS os, pl.arch AS arch, COUNT(*) AS total,
        SUM(ev.install_outcome) AS success, COUNT(*) - SUM(ev.install_outcome) AS failure
    }]
    set query [db_join $query [db_table packages -as p] -expr {ev.pkg_id = p.pkg_id}]
    set query [db_join $query [db_table package_names -as n] -expr {p.pkg_name_id = n.pkg_name_id}]
    set query [db_join $query [db_table platforms -as pl] -expr {ev.platform_id = pl.platform_id}]
    set query [db_where $query [db_eq [db_col name -table n] [db_value $package_name -type text]]]
    if {$package_version ne {}} {
        set query [db_where $query [db_eq [db_col version -table p] [db_value $package_version -type text]]]
    }
    set query [db_order_by [db_group_by $query -expr {pl.os, pl.arch}] -expr {pl.os, pl.arch}]
    lmap row [rows $query] {
        list "[dict get $row os] [dict get $row arch]" [dict get $row total] \
            [dict get $row success] [dict get $row failure]
    }
}
