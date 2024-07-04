# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2024 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.

package require sqlite3

namespace eval ::telemetry {

    # Define a list of known events and their parameters. This will be used
    # to validate arguments.
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

    variable event_statements {
        req_dist_get {
            INSERT INTO req_dist_get (env_id, platform_id)
            VALUES ($env_id, $platform_id)
        }
        req_pkg_get {
            INSERT INTO req_pkg_get (env_id, pkg_name_id)
            VALUES ($env_id, $pkg_name_id)
        }
        req_pkg_version_get {
            INSERT INTO req_pkg_version_get (env_id, pkg_id)
            VALUES ($env_id, $pkg_id)
        }
        req_pkg_install_event {
            INSERT INTO req_pkg_install_event (env_id, pkg_id, platform_id, install_outcome, install_is_toplevel)
            VALUES ($env_id, $pkg_id, $platform_id, $install_outcome, $install_is_toplevel)
        }
        req_reg_get_pkg_spec {
            INSERT INTO req_reg_get_pkg_spec (env_id, pkg_id, platform_id)
            VALUES ($env_id, $pkg_id, $platform_id)
        }
        req_reg_get_pkg {
            INSERT INTO req_reg_get_pkg (env_id, pkg_name_id)
            VALUES ($env_id, $pkg_name_id)
        }
        req_logo_get {
            INSERT INTO req_logo_get (env_id)
            VALUES ($env_id)
        }
    }

    variable known_os {
        {Linux}       {Linux}
        {Darwin}      {MacOS}
        {CYGWIN_NT-*} {Cygwin}
    }

    variable known_arch {
        aarch64 alpha arc arm i386 i486 i686 ia64
        m68k mips mips64 parisc ppc ppc64 ppc64le
        ppcle riscv64 s390 s390x sh sparc sparc64
        x86_64
    }

}

proc ::telemetry::init { args } {

    variable event_list

    for { set i 0 } { $i < [llength $args] } { incr i } {
        set arg [lindex $args $i]
        switch -exact -- $arg {
            -file {
                set db_file [lindex $args [incr i]]
            }
            default {
                return -code error "::telemetry::init error: unknown arg \"$arg\""
            }
        }
    }

    if { ![info exists db_file] } {
        return -code error "::telemetry::init required -file arg is not specified"
    }

    # Now sort the event parameters for optimization, as we will be comparing
    # them to the set parameters when the event was registered.
    dict for { k v } $event_list {
        dict set event_list $k [lsort $v]
    }

    sqlite3 db $db_file -fullmutex true

    db eval {
        PRAGMA foreign_keys = ON;
    }

    set actual_schema_version 3

    while { [set current_schema_version [db eval "PRAGMA user_version"]] < $actual_schema_version } {

        if { $current_schema_version == 0 } {
            db eval {

                CREATE TABLE environments (
                    env_id INTEGER PRIMARY KEY,
                    hash BLOB NOT NULL,
                    description TEXT,
                    last_seen INTEGER DEFAULT (unixepoch()) NOT NULL
                ) STRICT;

                CREATE INDEX idx_environments_hash ON environments(hash);

                CREATE TABLE package_names (
                    pkg_name_id INTEGER PRIMARY KEY,
                    name TEXT UNIQUE NOT NULL
                ) STRICT;

                CREATE TABLE packages (
                    pkg_id INTEGER PRIMARY KEY,
                    pkg_name_id INTEGER NOT NULL,
                    version TEXT NOT NULL,
                    UNIQUE (pkg_name_id, version),
                    FOREIGN KEY(pkg_name_id) REFERENCES package_names(pkg_name_id)
                ) STRICT;

                CREATE TABLE platforms (
                    platform_id INTEGER PRIMARY KEY,
                    os TEXT NOT NULL,
                    arch TEXT NOT NULL,
                    UNIQUE (os, arch)
                ) STRICT;

                CREATE TABLE req_dist_get (
                    timestamp INTEGER DEFAULT (unixepoch()) NOT NULL,
                    env_id INTEGER NOT NULL,
                    platform_id INTEGER NOT NULL,
                    FOREIGN KEY(env_id) REFERENCES environments(env_id),
                    FOREIGN KEY(platform_id) REFERENCES platforms(platform_id)
                ) STRICT;

                CREATE TABLE req_pkg_get (
                    timestamp INTEGER DEFAULT (unixepoch()) NOT NULL,
                    env_id INTEGER NOT NULL,
                    pkg_name_id INTEGER NOT NULL,
                    FOREIGN KEY(env_id) REFERENCES environments(env_id),
                    FOREIGN KEY(pkg_name_id) REFERENCES package_names(pkg_name_id)
                ) STRICT;

                CREATE TABLE req_reg_get_pkg_spec (
                    timestamp INTEGER DEFAULT (unixepoch()) NOT NULL,
                    env_id INTEGER NOT NULL,
                    pkg_id INTEGER NOT NULL,
                    platform_id INTEGER NOT NULL,
                    FOREIGN KEY(env_id) REFERENCES environments(env_id),
                    FOREIGN KEY(pkg_id) REFERENCES packages(pkg_id),
                    FOREIGN KEY(platform_id) REFERENCES platforms(platform_id)
                ) STRICT;

                CREATE TABLE req_reg_get_pkg (
                    timestamp INTEGER DEFAULT (unixepoch()) NOT NULL,
                    env_id INTEGER NOT NULL,
                    pkg_name_id INTEGER NOT NULL,
                    FOREIGN KEY(env_id) REFERENCES environments(env_id),
                    FOREIGN KEY(pkg_name_id) REFERENCES package_names(pkg_name_id)
                ) STRICT;

                CREATE TABLE req_logo_get (
                    timestamp INTEGER DEFAULT (unixepoch()) NOT NULL,
                    env_id INTEGER NOT NULL,
                    FOREIGN KEY(env_id) REFERENCES environments(env_id)
                ) STRICT;

                PRAGMA user_version = 1;
            }
        }

        if { $current_schema_version == 1 } {
            db eval {
                CREATE TABLE req_pkg_install_event (
                    timestamp INTEGER DEFAULT (unixepoch()) NOT NULL,
                    env_id INTEGER NOT NULL,
                    platform_id INTEGER NOT NULL,
                    pkg_id INTEGER NOT NULL,
                    install_outcome INTEGER NOT NULL,
                    install_is_toplevel INTEGER NOT NULL,
                    FOREIGN KEY(env_id) REFERENCES environments(env_id),
                    FOREIGN KEY(pkg_id) REFERENCES packages(pkg_id)
                    FOREIGN KEY(platform_id) REFERENCES platforms(platform_id)
                ) STRICT;

                PRAGMA user_version = 2;
            }
        }

        if { $current_schema_version == 2 } {

            db eval {
                CREATE TABLE req_pkg_version_get (
                    timestamp INTEGER DEFAULT (unixepoch()) NOT NULL,
                    env_id INTEGER NOT NULL,
                    pkg_id INTEGER NOT NULL,
                    FOREIGN KEY(env_id) REFERENCES environments(env_id),
                    FOREIGN KEY(pkg_id) REFERENCES packages(pkg_id)
                ) STRICT;

                PRAGMA user_version = 3;
            }
        }
    }
}

proc ::telemetry::sql { sql vars } {
    dict for { k v } $vars {
        set $k $v
    }
    db eval $sql
}

proc ::telemetry::event { event_type args } {

    variable event_list
    variable event_statements
    variable known_arch
    variable known_os

    if { $event_type ni [dict keys $event_list] } {
        return -code error "::telemetry::event error: unknown event \"$event_type\""
    }

    # Check if args is correct dict
    if { [catch { dict size $args }] } {
        return -code error "::telemetry::event error: event arguments must have\
            an even number of parameters"
    }

    # Check if arguments for given event are as expected
    if { [lsort [dict keys $args]] != [dict get $event_list $event_type] } {
        return -code error "::telemetry::event error: wrong args for event\
            \"$event_type\": \"[lsort [dict keys $args]]\"; expected set\
            of parameters: \"[dict get $event_list $event_type]\""
    }

    # Convert dictionary to variables
    dict for { k v } $args {
        set [string range $k 1 end] $v
    }

    if { $event_type eq "register_environment" } {
        set env_id [db eval {
            SELECT env_id FROM environments WHERE hash = unhex($env) AND description = $description
        }]
        # If we already have this environment, then update the timestamp.
        # If we don't have it, then add it.
        if { [string length $env_id] } {
            db eval {
                UPDATE environments SET last_seen = unixepoch() WHERE env_id = $env_id
            }
        } else {
            db eval {
                INSERT INTO environments (hash, description) VALUES (unhex($env), $description)
            }
        }
        return
    }

    # All other events expect env_id as id from environment table
    if { [info exists env] } {
        set env_id [db eval {
            SELECT env_id FROM environments WHERE hash = unhex($env) ORDER BY last_seen DESC LIMIT 1
        }]
        if { ![string length $env_id] } {
            return -code error "::telemetry::event error: unknown environment \"$env\""
        }
    }

    # If event uses pkg_name then convert it to pkg_name_id from the table package_names
    if { [info exists pkg_name] } {
        set pkg_name_id [db eval {
            INSERT INTO package_names (name) VALUES ($pkg_name)
            ON CONFLICT(name) DO UPDATE SET name=name
            RETURNING pkg_name_id
        }]
        if { ![string length $pkg_name_id] } {
            return -code error "::telemetry::event error: failed to get pkg_name_id"
        }
    }

    # If event uses pkg_version then convert it to pkg_id from the table packages
    if { [info exists pkg_version] } {
        set pkg_id [db eval {
            INSERT INTO packages (pkg_name_id, version) VALUES ($pkg_name_id, $pkg_version)
            ON CONFLICT(pkg_name_id, version) DO UPDATE SET version=version
            RETURNING pkg_id
        }]
        if { ![string length $pkg_id] } {
            return -code error "::telemetry::event error: failed to get pkg_id"
        }
    }

    # If event uses os/arch then convert them to platform_id from the table platforms
    if { [info exists os] && [info exists arch] } {

        if { $arch ni $known_arch } {
            return -code error "::telemetry::event error: unknown arch \"$arch\""
        }

        if { $os in [dict keys $known_os] } {
            set os [dict get $known_os $os]
        } else {
            set found 0
            dict for { k v } $known_os {
                if { [string match $k $os] } {
                    set os $v
                    set found 1
                    break
                }
            }
            if { !$found } {
                return -code error "::telemetry::event error: unknown os \"$os\""
            }
        }

        set platform_id [db eval {
            INSERT INTO platforms (os, arch) VALUES ($os, $arch)
            ON CONFLICT(os, arch) DO UPDATE SET os=os
            RETURNING platform_id
        }]
        if { ![string length $platform_id] } {
            return -code error "::telemetry::event error: failed to get platform_id"
        }
    } else {
        # Both os and arch must be specified. Do not allow just one of these variables
        # to be specified, as that value will not be filtered. So make sure we
        # don't have these variables by unsetting them.
        unset -nocomplain os arch
    }

    db eval [dict get $event_statements $event_type]

}
