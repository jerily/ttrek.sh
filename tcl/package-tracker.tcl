# Copyright Jerily LTD. All Rights Reserved.
# SPDX-License-Identifier: MIT.

# Derived activity lives in Valkey. Only the private refresh task aggregates SQL;
# HTTP requests read a snapshot and resolve links against the current catalog.
namespace eval ::package_tracker {
    variable client {}
    variable settings {}
    variable prefix {ttrek:package-tracker:v2}
    variable limit 5
    variable defaults {min_current 10 min_previous 5 min_delta 5 min_growth 25}
}

proc ::package_tracker::configure {config} {
    variable client
    variable settings
    if {$client ne {}} {catch {$client destroy}; set client {}}
    set settings $config
}

proc ::package_tracker::thresholds {} {
    variable defaults
    variable settings
    set result $defaults
    if {[dict exists $settings thresholds]} {set result [dict merge $result [dict get $settings thresholds]]}
    dict for {key value} $result {
        if {![dict exists $defaults $key] || ![string is integer -strict $value] || $value < 1} {
            error "Invalid Package Tracker threshold: $key"
        }
    }
    return $result
}

proc ::package_tracker::cache {args} {
    variable client
    variable settings
    try {
        if {$client eq {}} {
            if {![dict exists $settings valkey]} {error "Package Tracker cache is not configured"}
            package require valkey 1.0.3
            set config [dict get $settings valkey]
            set options {}
            if {[dict exists $config ssl] && [dict get $config ssl]} {lappend options -ssl}
            foreach key {host port username password ssl_ca_file ssl_cert_file ssl_key_file} {
                if {[dict exists $config $key]} {lappend options -$key [dict get $config $key]}
            }
            # An optional discovery panel must not add a long network timeout.
            lappend options -timeout 1000
            set client [valkey {*}$options]
        }
        $client raw {*}$args
    } on error {message options} {
        if {$client ne {}} {catch {$client destroy}; set client {}}
        return -code error -errorcode {TRACKER CACHE} "Package Tracker cache is unavailable"
    }
}

# Explicit types keep empty arrays, zero counts and numeric-looking names intact.
proc ::package_tracker::typed_record {record} {
    set fields {}
    dict for {key value} $record {
        if {$key in {days rows sections}} {
            dict set fields $key [list L [lmap row $value {typed_record $row}]]
        } elseif {$key eq "thresholds"} {
            dict set fields $key [typed_record $value]
        } elseif {$key in {format as_of history_start trend_ready start recent_start baseline_start
                total current previous delta growth active_days count timestamp partial available
                min_current min_previous min_delta min_growth stale chart_ready has_entries}} {
            dict set fields $key [list N $value]
        } else {dict set fields $key [list S $value]}
    }
    return [list M $fields]
}

proc ::package_tracker::json {record} {::tjson::typed_to_json [typed_record $record]}

proc ::package_tracker::require_numbers {record keys {minimum 0}} {
    foreach key $keys {
        set value [dict get $record $key]
        if {![string is entier -strict $value] || $value < $minimum} {error "Invalid tracker snapshot"}
    }
}

proc ::package_tracker::validate_field {field value} {
    if {[string match pkg:* $field]} {
        require_numbers $value {total current previous active_days}
        require_numbers $value delta -9223372036854775808
        if {![string is double -strict [dict get $value growth]]} {error "Invalid tracker growth"}
        set days [dict get $value days]
        if {[llength $days] < 30 || [llength $days] > 31} {error "Invalid tracker days"}
        foreach day $days {
            require_numbers $day count
            if {![regexp {^[0-9]{4}-[0-9]{2}-[0-9]{2}$} [dict get $day date]] ||
                [dict get $day available] ni {0 1} || [dict get $day partial] ni {0 1}} {error "Invalid tracker day"}
        }
    } else {
        set rows [dict get $value rows]
        # Accept the previous ten-entry format until the next refresh; read
        # trims it to the current display limit after validating the payload.
        if {[llength $rows] > 10} {error "Invalid tracker ranking"}
        foreach row $rows {
            foreach key {name version} {
                if {![::recipe_search::valid_name [dict get $row $key]]} {error "Invalid tracker package"}
            }
            if {$field in {new updated}} {
                require_numbers $row timestamp
            } elseif {$field eq "popular"} {require_numbers $row count
            } else {
                require_numbers $row {current previous delta}
                if {![string is double -strict [dict get $row growth]] || [dict get $row growth] <= 0} {error "Invalid tracker growth"}
            }
        }
    }
}

# A deterministic ordering also makes equal publication dates useful at rollout.
proc ::package_tracker::compare {fields a b} {
    foreach field $fields {
        set left [dict get $a $field]
        set right [dict get $b $field]
        if {$left > $right} {return -1}
        if {$left < $right} {return 1}
    }
    string compare [dict get $a name] [dict get $b name]
}

proc ::package_tracker::aggregate {{now {}}} {
    variable limit
    if {$now eq {}} {set now [clock seconds]}
    if {![string is entier -strict $now] || $now < 2592000} {error "Invalid tracker cutoff"}
    set limits [thresholds]
    set start [expr {$now - 30 * 86400}]
    set recent [expr {$now - 7 * 86400}]
    set baseline [expr {$now - 14 * 86400}]
    set params [dict create start $start recent $recent baseline $baseline cutoff $now]
    set connection $::telemetry::connection
    ::telemetry::transaction {
        if {$::telemetry::dialect eq "postgresql"} {
            ::tpersist::_raw $connection {SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY}
            ::tpersist::_raw $connection {SET LOCAL statement_timeout = '20s'}
        }
        set catalog [::recipe_search::catalog_entries [::telemetry::registry_catalog]]
        # The time-leading index bounds work to 30 days. Aggregate daily rows in
        # SQL; never transfer individual events or environment identifiers.
        set activity [::tpersist::_raw $connection {
            SELECT n.name, CAST(ev.timestamp / 86400 AS BIGINT) AS day, COUNT(DISTINCT e.hash) AS total
            FROM req_reg_get_pkg_spec ev
            JOIN environments e ON e.env_id = ev.env_id
            JOIN packages p ON p.pkg_id = ev.pkg_id
            JOIN package_names n ON n.pkg_name_id = p.pkg_name_id
            WHERE ev.timestamp >= :start AND ev.timestamp < :cutoff AND p.listed = 1
            GROUP BY n.name, CAST(ev.timestamp / 86400 AS BIGINT)
        } $params]
        # Deduplicate independently over each full window, never by summing
        # daily unique counts. Versions and registration changes share a hash.
        set unique [::tpersist::_raw $connection {
            SELECT n.name, COUNT(DISTINCT e.hash) AS total,
                COUNT(DISTINCT CASE WHEN ev.timestamp >= :recent THEN e.hash END) AS current,
                COUNT(DISTINCT CASE WHEN ev.timestamp >= :baseline AND ev.timestamp < :recent THEN e.hash END) AS previous
            FROM req_reg_get_pkg_spec ev
            JOIN environments e ON e.env_id = ev.env_id
            JOIN packages p ON p.pkg_id = ev.pkg_id
            JOIN package_names n ON n.pkg_name_id = p.pkg_name_id
            WHERE ev.timestamp >= :start AND ev.timestamp < :cutoff AND p.listed = 1
            GROUP BY n.name
        } $params]
        set history [::tpersist::_raw $connection {
            SELECT MIN(timestamp) AS since FROM req_reg_get_pkg_spec WHERE timestamp < :cutoff
        } [dict create cutoff $now]]
    }
    set history_start 0
    if {[dict exists [lindex $history 0] since] && [dict get [lindex $history 0] since] ne {}} {
        set history_start [dict get [lindex $history 0] since]
    }
    set ready [expr {$history_start > 0 && $history_start <= $baseline}]
    set meta [dict create format 2 as_of $now start $start recent_start $recent baseline_start $baseline \
        history_start $history_start trend_ready $ready thresholds $limits]
    set packages {}
    dict for {name entry} $catalog {
        dict set packages $name [dict create total 0 current 0 previous 0 delta 0 growth 0 \
            active_days 0 days {}]
    }
    set buckets {}
    foreach row $activity {
        set name [dict get $row name]
        if {![dict exists $packages $name]} continue
        set stats [dict get $packages $name]
        dict incr stats active_days
        dict set packages $name $stats
        dict set buckets $name [dict get $row day] [dict get $row total]
    }
    foreach row $unique {
        set name [dict get $row name]
        if {![dict exists $packages $name]} continue
        foreach key {total current previous} {dict set packages $name $key [dict get $row $key]}
    }
    set rankings [dict create new {} updated {} popular {} trending {}]
    dict for {name entry} $catalog {
        set versions [dict get $entry versions]
        set latest [lindex [lsort -command ::compare_versions -decreasing [dict keys $versions]] 0]
        set row [dict get $versions $latest]
        set first [dict get $row first_published_at]
        if {$first >= $start && $first <= $now} {
            dict lappend rankings new [dict create name $name version $latest timestamp $first]
        }
        set updates {}
        dict for {version details} $versions {
            set timestamp [dict get $details published_at]
            if {[dict get $details publication_is_update] && $timestamp >= $start && $timestamp <= $now} {
                lappend updates [dict create name $name version $version timestamp $timestamp]
            }
        }
        if {[llength $updates]} {
            # Prefer the higher version when a single sync publishes several.
            set updates [lsort -command {apply {{a b} {compare_versions [dict get $b version] [dict get $a version]}}} $updates]
            dict lappend rankings updated [lindex [lsort -command [list compare {timestamp}] $updates] 0]
        }
        set stats [dict get $packages $name]
        set current [dict get $stats current]
        set previous [dict get $stats previous]
        set delta [expr {$current - $previous}]
        set growth [expr {$previous > 0 ? 100.0 * $delta / $previous : 0.0}]
        dict set stats delta $delta
        dict set stats growth $growth
        set days {}
        for {set day [expr {$start / 86400}]} {$day <= ($now - 1) / 86400} {incr day} {
            set count 0
            if {[dict exists $buckets $name $day]} {set count [dict get $buckets $name $day]}
            lappend days [dict create date [clock format [expr {$day * 86400}] -format %Y-%m-%d -gmt true] \
                count $count available [expr {$history_start > 0 && ($day + 1) * 86400 > $history_start}] \
                partial [expr {$day * 86400 < $start || ($day + 1) * 86400 > $now}]]
        }
        dict set stats days $days
        dict set packages $name $stats
        if {[dict get $stats total] > 0} {
            dict lappend rankings popular [dict create name $name version $latest count [dict get $stats total]]
        }
        if {$ready && $current >= [dict get $limits min_current] && $previous >= [dict get $limits min_previous] &&
                $delta >= [dict get $limits min_delta] && $growth >= [dict get $limits min_growth]} {
            dict lappend rankings trending [dict create name $name version $latest current $current previous $previous \
                delta $delta growth $growth]
        }
    }
    foreach {id fields} {new timestamp updated timestamp popular count trending {growth delta}} {
        dict set rankings $id [lrange [lsort -command [list compare $fields] [dict get $rankings $id]] 0 [expr {$limit - 1}]]
    }
    return [dict create meta $meta rankings $rankings packages $packages]
}

# One hash is a complete generation. RENAME switches metadata, rankings and
# package statistics atomically; a fencing token rejects an expired worker.
proc ::package_tracker::publish {snapshot token} {
    variable prefix
    set staged $prefix:staged:$token
    try {
        cache HSET $staged meta [json [dict get $snapshot meta]]
        cache EXPIRE $staged 86400
        dict for {id rows} [dict get $snapshot rankings] {cache HSET $staged $id [json [dict create rows $rows]]}
        dict for {name stats} [dict get $snapshot packages] {cache HSET $staged pkg:$name [json $stats]}
        set published [cache EVAL {
            if redis.call('GET', KEYS[1]) ~= ARGV[1] then return 0 end
            redis.call('RENAME', KEYS[2], KEYS[3])
            return 1
        } 3 $prefix:lock $staged $prefix:active $token]
        if {$published != 1} {error "Package Tracker refresh lease expired"}
    } finally {catch {cache DEL $staged}}
}

proc ::package_tracker::refresh {} {
    variable prefix
    set token [format {%s-%s-%s} [pid] [clock microseconds] [expr {int(rand() * 2147483647)}]]
    if {[cache SET $prefix:lock $token NX EX 240] ne "OK"} {return skipped}
    set started [clock milliseconds]
    try {
        publish [aggregate] $token
        puts "Package Tracker refreshed in [expr {[clock milliseconds] - $started}] ms"
        return refreshed
    } on error {message options} {
        puts stderr "Package Tracker refresh failed; retaining the previous snapshot."
        return -code error -errorcode {TRACKER REFRESH} "Package Tracker refresh failed"
    } finally {
        catch {cache EVAL {
            if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('DEL', KEYS[1]) end
            return 0
        } 1 $prefix:lock $token}
    }
}

# HMGET observes a single complete generation, including during publication.
# Missing cache data is unavailable, never a fabricated zero download count.
proc ::package_tracker::read {{name {}}} {
    variable settings
    variable prefix
    variable limit
    if {![dict exists $settings valkey]} {return {}}
    try {
        set fields [expr {$name eq {} ? {new updated popular trending} : [list pkg:$name]}]
        set values [cache HMGET $prefix:active meta {*}$fields]
        set meta [::tjson::json_to_simple [lindex $values 0]]
        set now [clock seconds]
        require_numbers $meta {format as_of start recent_start baseline_start history_start trend_ready}
        variable defaults
        require_numbers [dict get $meta thresholds] [dict keys $defaults] 1
        if {[dict get $meta format] != 2 || ![string is entier -strict [dict get $meta as_of]] ||
                [dict get $meta as_of] > $now + 60 || $now - [dict get $meta as_of] >= 86400} {return {}}
        dict set meta stale [expr {$now - [dict get $meta as_of] > 900}]
        set result [dict create meta $meta]
        foreach field $fields value [lrange $values 1 end] {
            if {$value eq {}} {return {}}
            set decoded [::tjson::json_to_simple $value]
            validate_field $field $decoded
            if {$name eq {}} {dict set decoded rows [lrange [dict get $decoded rows] 0 [expr {$limit - 1}]]}
            dict set result $field $decoded
        }
        return $result
    } on error {message options} {return {}}
}

proc ::package_tracker::date {timestamp} {
    if {$timestamp <= 0} {return {}}
    clock format $timestamp -format {%b %d, %Y} -gmt true
}

proc ::package_tracker::sections {snapshot catalog} {
    set result {}
    foreach {id title period empty} {
        new New {First registry inclusion · last 30 days} {No new packages in the last 30 days.}
        updated {Recently Updated} {New registry versions · last 30 days} {No new versions published in the last 30 days.}
        popular Popular {Unique recipe downloads · last 30 days} {No identified recipe downloads recorded in the last 30 days.}
        trending Trending {Unique recipe downloads · last 7 days vs. preceding 7 days} {Not enough qualifying activity to establish a trend yet.}
    } {
        set rows {}
        if {$snapshot eq {}} {set empty {Activity is temporarily unavailable. Please check back soon.}
        } else {
            foreach row [dict get $snapshot $id rows] {
                set name [dict get $row name]
                set version [dict get $row version]
                if {![dict exists $catalog $name versions $version]} continue
                dict set row description [dict get $catalog $name description]
                if {$id in {new updated}} {
                    set metric [date [dict get $row timestamp]]
                } elseif {$id eq "popular"} {
                    set metric "[dict get $row count] unique downloads"
                } else {
                    set metric [format {+%.0f%% · %s → %s unique downloads} [dict get $row growth] [dict get $row previous] [dict get $row current]]
                }
                dict set row metric $metric
                lappend rows $row
            }
        }
        lappend result [dict create id $id title $title period $period empty $empty rows $rows]
    }
    return $result
}

proc ::package_tracker::view {catalog {catalog_available true}} {
    set snapshot {}
    if {$catalog_available} {set snapshot [read]}
    set sections [sections $snapshot $catalog]
    set has_entries 0
    foreach section $sections {
        if {[llength [dict get $section rows]]} {set has_entries 1; break}
    }
    set data [dict create available [expr {$snapshot ne {}}] has_entries $has_entries sections $sections]
    if {$snapshot ne {}} {
        dict set data updated [clock format [dict get $snapshot meta as_of] -format {%b %d, %Y at %H:%M UTC} -gmt true]
        dict set data stale [dict get $snapshot meta stale]
        dict set data thresholds [dict get $snapshot meta thresholds]
        dict set data since [date [dict get $snapshot meta history_start]]
    } else {dict set data thresholds [thresholds]}
    typed_record $data
}

proc get_package_tracker_page_handler {ctx req} {
    set available [expr {![catch {::recipe_search::catalog_entries [::telemetry::registry_catalog]} catalog]}]
    if {!$available} {
        set catalog {}
    }
    set data [dict create title {S {Package Tracker}} tracker [::package_tracker::view $catalog $available]]
    ::twebserver::build_response 200 {text/html; charset=utf-8} [::views::render package-tracker.html.jinja $data]
}

proc get_package_tracker_redirect_handler {ctx req} {
    ::twebserver::build_redirect 301 /packages/tracker
}
