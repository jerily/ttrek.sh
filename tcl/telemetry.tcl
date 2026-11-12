# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2024 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.

# Drivers are loaded by tpersist only when the selected backend connects.
package require tpersist
source [file join [file dirname [info script]] registry-metadata.tcl]

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

# Runtime startup opens the connection only. Provisioning is explicit.
proc ::telemetry::connect {settings} {
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
}

# Explicit fixture/provisioning helper. Runtime startup always uses connect.
proc ::telemetry::init_local {settings {registryDirectories {}}} {
    connect $settings
    try {
        initdb
        transaction {
            lock_search_snapshot
            if {[llength $registryDirectories]} {sync_registry_metadata {*}$registryDirectories}
            publish_search_snapshot
        }
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
        pkg_id $id pkg_name_id $required version {type text not_null 1} \
        description [dict create type text not_null 1 default [db_value {} -type text]] \
        url [dict create type text not_null 1 default [db_value {} -type text]] \
        tags [dict create type text not_null 1 default [db_value {[]} -type text]] \
        listed [dict create type integer not_null 1 default [db_value 0 -type integer]]] \
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

proc ::telemetry::initdb {} {
    variable connection
    variable dialect
    transaction {
        dict for {table definition} [table_definitions] {
            db_create_table $connection $definition -if_not_exists true
        }
        # Upgrade existing databases without replacing package IDs or event rows.
        # Adding listed defaults legacy rows to 0 until the first registry sync
        # identifies published recipes. Existing listed flags are never reset.
        # tpersist has no ALTER TABLE helper; only fixed schema identifiers enter SQL.
        if {$dialect eq "sqlite"} {
            set columns [lmap row [::tpersist::_raw $connection {PRAGMA table_info(packages)}] {dict get $row name}]
        } else {
            set columns [lmap row [::tpersist::_raw $connection {
                SELECT attname FROM pg_attribute
                WHERE attrelid = 'packages'::regclass AND attnum > 0 AND NOT attisdropped
            }] {dict get $row attname}]
        }
        foreach {column definition} {
            description {TEXT NOT NULL DEFAULT ''}
            url {TEXT NOT NULL DEFAULT ''}
            tags {TEXT NOT NULL DEFAULT '[]'}
            listed {INTEGER NOT NULL DEFAULT 0}
        } {
            if {$column ni $columns} {
                set guard [expr {$dialect eq "postgresql" ? "IF NOT EXISTS " : ""}]
                ::tpersist::_raw $connection "ALTER TABLE packages ADD COLUMN ${guard}$column $definition"
            }
        }
        db_create_index $connection idx_environments_hash environments {hash} -if_not_exists true
        db_create_index $connection idx_install_package req_pkg_install_event {pkg_id platform_id} -if_not_exists true
        init_search_snapshot
    } true
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

# Read and validate every recipe before writing. Registry paths are explicit so
# private registries can be imported locally without being bundled on the site.
proc ::telemetry::sync_registry_metadata {args} {
    variable connection
    package require tjson
    set catalog {}
    foreach directory $args {
        if {![file isdirectory $directory]} {error "Registry directory does not exist: $directory"}
        foreach path [lsort -ascii [glob -nocomplain -directory $directory -types f */*/ttrek.json]] {
            set channel [open $path r]
            try {
                fconfigure $channel -encoding utf-8
                ::tjson::parse [read $channel] spec
            } finally {::close $channel}
            if {![::tjson::is_object $spec]} {error "Expected a recipe object in $path"}
            set tags {}
            if {[::tjson::has_object_item $spec tags]} {
                set tags [::registry_metadata::tags [::tjson::to_typed [::tjson::get_object_item $spec tags]] $path]
            }
            set metadata [dict create tags [::tjson::typed_to_json [list L [lmap tag $tags {list S $tag}]]]]
            foreach field {description url} {
                if {![::tjson::has_object_item $spec $field]} continue
                set item [::tjson::get_object_item $spec $field]
                if {![::tjson::is_string $item]} {error "$field must be a string in $path"}
                dict set metadata $field [::tjson::get_valuestring $item]
            }
            set version [file tail [file dirname $path]]
            set name [file tail [file dirname [file dirname $path]]]
            set key [list $name $version]
            if {[dict exists $catalog $key]} {error "Duplicate registry package: $name@$version"}
            dict set catalog $key $metadata
        }
    }
    transaction {
        # Avoid rewriting unchanged catalog rows during repeated syncs.
        lock_search_snapshot
        set existing {}
        set query [db_join [db_select packages -expr {name, version, pkg_id, description, url, tags, listed}] \
            package_names -expr {packages.pkg_name_id = package_names.pkg_name_id}]
        foreach row [rows $query] {
            dict set existing [list [dict get $row name] [dict get $row version]] $row
        }
        dict for {key metadata} $catalog {
            lassign $key name version
            if {[dict exists $existing $key]} {
                set row [dict get $existing $key]
                set changes {}
                if {![dict get $row listed]} {dict set changes listed [db_value 1 -type integer]}
                dict for {field value} $metadata {
                    if {[dict get $row $field] ne $value} {
                        dict set changes $field [db_value $value -type text]
                    }
                }
                if {![dict size $changes]} continue
                set pkg_id [dict get $row pkg_id]
            } else {
                set name_id [ensure_row package_names pkg_name_id [dict create name [db_value $name -type text]]]
                set pkg_id [ensure_row packages pkg_id [dict create \
                    pkg_name_id [db_value $name_id -type integer] version [db_value $version -type text]]]
                set changes [dict create listed [db_value 1 -type integer]]
                dict for {field value} $metadata {dict set changes $field [db_value $value -type text]}
                if {![dict size $changes]} continue
            }
            db_execute $connection [db_where [db_values [db_update packages] $changes -expressions] \
                [db_eq [db_col pkg_id] [db_value $pkg_id -type integer]]]
        }
        # Keep telemetry history while removing withdrawn versions from discovery.
        dict for {key row} $existing {
            if {[dict get $row listed] && ![dict exists $catalog $key]} {
                db_execute $connection [db_where [db_values [db_update packages] {listed 0}] \
                    [db_eq [db_col pkg_id] [db_value [dict get $row pkg_id] -type integer]]]
            }
        }
    }
    return [dict size $catalog]
}

# The website reads this catalog, never recipe metadata or a build-time file.
# Telemetry-only package names and withdrawn versions remain outside discovery.
proc ::telemetry::registry_catalog {args} {
    package require tjson
    if {[llength $args] > 1} {error "Expected an optional list of package names"}
    set query [db_join [db_select packages -expr {name, version, description, url, tags}] \
        package_names -expr {packages.pkg_name_id = package_names.pkg_name_id}]
    set predicate [db_eq [db_col listed] [db_value 1 -type integer]]
    if {[llength $args]} {
        set names [lindex $args 0]
        set predicate [db_and $predicate [db_in [db_col name] [lmap name $names {db_value $name -type text}]]]
    }
    set query [db_order_by [db_where $query $predicate] -expr {name, version}]
    set result {}
    foreach row [rows $query] {
        dict set row tags [::registry_metadata::tags [::tjson::json_to_typed [dict get $row tags]] database]
        lappend result $row
    }
    return $result
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

source [file join [file dirname [info script]] search-store.tcl]
