source [file join [file dirname [info script]] search-snapshot.tcl]

proc ::recipe_search::query {text} {
    if {[string length $text] > 255 || ![regexp {^[A-Za-z0-9._+ -]+$} $text]} {error "Invalid search query"}
    set text [fold [string trim $text " "]]
    if {$text in {{} . ..}} {error "Invalid search query"}
    return $text
}

proc ::recipe_search::reset {} {
    foreach command {index descriptions} {
        if {[llength [info commands ::recipe_search::$command]]} {::recipe_search::$command destroy}
    }
    discard_staged
    variable entries {}
    variable documents {}
    unset -nocomplain ::recipe_search::revision
}

proc ::recipe_search::database {command args} {
    ::telemetry::$command {*}$args
}

proc ::recipe_search::refresh {} {
    variable revision
    try {
        if {[info exists revision] && [database search_snapshot_revision] eq $revision} {return 1}
        # Use the payload's own revision: publication may occur after the check.
        load_snapshot [database search_snapshot]
        return 1
    } on error {message options} {
        puts stderr "Search snapshot refresh failed; keeping the last validated indexes if available."
        return [info exists revision]
    }
}

proc ::recipe_search::unavailable {} {
    set response [::twebserver::build_response 503 text/plain {Package search is temporarily unavailable.}]
    dict set response headers Retry-After 30
    dict set response headers Cache-Control no-store
    return $response
}

# Display data is fetched after ranking, only for the matching package names.
proc ::recipe_search::catalog_entries {rows} {
    set grouped {}
    foreach row $rows {
        set name [dict get $row name]
        set version [dict get $row version]
        if {![valid_name $name] || ![valid_name $version]} continue
        dict set grouped $name $version $row
    }
    set catalog {}
    foreach name [lsort -ascii [dict keys $grouped]] {
        set texts {}
        set tags {}
        dict for {version row} [dict get $grouped $name] {
            if {[dict get $row description] ne {}} {lappend texts [dict get $row description]}
            lappend tags {*}[dict get $row tags]
        }
        dict set catalog $name [dict create name $name description [lindex [lsort -ascii -unique $texts] 0] \
            tags [lsort -ascii -unique $tags] versions [dict get $grouped $name]]
    }
    return $catalog
}

proc ::recipe_search::results {text {limit 0}} {
    variable revision
    for {set attempt 0} {$attempt < 3} {incr attempt} {
        if {![refresh]} {error "Search snapshot is unavailable"}
        set matches [search $text]
        if {$limit > 0} {set matches [lrange $matches 0 [expr {$limit - 1}]]}
        set names [lmap match $matches {dict get $match name}]
        try {
            set rows [database search_result_metadata $revision $names]
        } on error {message options} {
            if {[dict get $options -errorcode] eq {SEARCH REVISION}} {continue}
            return -options $options $message
        }
        set metadata [catalog_entries $rows]
        set results {}
        foreach match $matches {
            set name [dict get $match name]
            set data [dict get $metadata $name]
            set description [dict get $data description]
            if {[dict get $match tier] in {3 6}} {
                set description [dict get $data versions [dict get $match version] description]
            }
            dict set match description $description
            dict set match tags [dict get $data tags]
            lappend results [dict remove $match version]
        }
        return $results
    }
    error "Search catalog changed repeatedly during the request"
}

proc ::recipe_search::compare {a b} {
    foreach field {tier distance negative_coverage unmatched} {
        set left [dict get $a $field]
        set right [dict get $b $field]
        if {$left < $right} {return -1}
        if {$left > $right} {return 1}
    }
    string compare [dict get $a name] [dict get $b name]
}

proc ::recipe_search::search {text} {
    variable entries
    variable documents
    set text [query $text]
    set limit [expr {[string length $text] <= 3 ? 1 : 2}]
    set fuzzy {}
    foreach match [index search $text $limit] {dict set fuzzy [dict get $match name] [dict get $match distance]}
    set found {}
    dict for {name data} $entries {
        set normalized [dict get $data normalized]
        set tier 8
        set distance 0
        set unmatched 0
        if {$normalized eq $text} {set tier 0
        } elseif {[string first $text $normalized] == 0} {set tier 1
        } elseif {[string first $text $normalized] >= 0} {set tier 2
        } elseif {[dict exists $fuzzy $normalized]} {
            set tier 5
            set distance [dict get $fuzzy $normalized]
        }
        if {$tier in {1 2}} {set unmatched [expr {[string length $name] - [string length $text]}]}
        dict set found $name [dict create name $name version {} \
            tier $tier distance $distance negative_coverage 0 unmatched $unmatched query_trigrams 0 shared_trigrams 0]
    }
    foreach match [descriptions search $text $limit] {
        lassign [lindex $documents [dict get $match document]] name version field
        set distance [dict get $match distance]
        set shared [dict get $match shared_trigrams]
        set total [dict get $match query_trigrams]
        set tier [expr {($distance == 0 ? 3 : 6) + ($field eq "tags")}]
        set candidate [dict create name $name version $version tier $tier distance $distance \
            negative_coverage [expr {-$shared}] unmatched 0 query_trigrams $total shared_trigrams $shared]
        if {[compare $candidate [dict get $found $name]] < 0} {dict set found $name $candidate}
    }
    set results {}
    foreach match [lsort -command ::recipe_search::compare [dict values $found]] {
        if {[dict get $match tier] < 8} {lappend results $match}
    }
    return $results
}

proc ::recipe_search::request_query {request} {
    # Decode raw query text once; preserve repeated values as arrays for validation.
    set values {}
    if {[dict exists $request queryString]} {
        foreach pair [split [dict get $request queryString] &] {
            set separator [string first = $pair]
            if {$separator < 0} {continue}
            set key [::twebserver::decode_uri_component [string range $pair 0 [expr {$separator - 1}]] utf-8]
            if {$key eq "q"} {
                lappend values [::twebserver::decode_uri_component [string range $pair [expr {$separator + 1}] end] utf-8]
            }
        }
    } elseif {[dict exists $request multiValueQueryStringParameters q]} {
        set values [dict get $request multiValueQueryStringParameters q]
    } elseif {[dict exists $request queryStringParameters q]} {
        set values [list [dict get $request queryStringParameters q]]
    }
    set input [dict create httpMethod GET]
    if {[llength $values] == 1} {
        dict set input queryStringParameters q [lindex $values 0]
    } elseif {[llength $values] > 1} {
        dict set input multiValueQueryStringParameters q $values
    }
    ::request_validation::check search $input
    return [query [lindex $values 0]]
}

proc get_search_handler {ctx req} {
    if {[catch {::recipe_search::request_query $req} query]} {
        return [::twebserver::build_response 400 text/plain \
            "q must contain 1 to 255 ASCII letters, digits, spaces, '.', '_', '+' or '-'"]
    }
    set matches {}
    if {[catch {::recipe_search::results $query} results]} {return [::recipe_search::unavailable]}
    foreach match $results {
        set tier [dict get $match tier]
        set kind [lindex {exact prefix substring description description fuzzy description-fuzzy description-fuzzy} $tier]
        set total [dict get $match query_trigrams]
        set fields [dict create name [list S [dict get $match name]] \
            description [list S [dict get $match description]] match [list S $kind] \
            tags [list L [lmap tag [dict get $match tags] {list S $tag}]]]
        # Older CLI clients understand description matches; new clients use field to rank tags third.
        if {$tier in {4 7}} {dict set fields field {S tags}}
        if {$tier ni {1 2}} {dict set fields distance [list N [dict get $match distance]]}
        if {$total} {dict set fields coverage [list N [expr {double([dict get $match shared_trigrams]) / $total}]]}
        lappend matches [list M $fields]
    }
    return [::twebserver::build_response 200 application/json \
        [::tjson::typed_to_json [list L $matches]]]
}

# JSON suggestions and HTML results share the current database catalog.
proc get_autocomplete_handler {ctx req} {
    if {[catch {::recipe_search::request_query $req} query]} {
        return [::twebserver::build_response 400 text/plain "Invalid search query"]
    }
    if {[catch {::recipe_search::results $query 8} results]} {return [::recipe_search::unavailable]}
    set suggestions {}
    foreach match $results {
        lappend suggestions [list M [dict create name [list S [dict get $match name]] \
            description [list S [dict get $match description]]]]
    }
    return [::twebserver::build_response 200 application/json \
        [::tjson::typed_to_json [list L $suggestions]]]
}

proc ::recipe_search::cards {matches} {
    set cards {}
    foreach match $matches {
        set fields [dict create name [list S [dict get $match name]] \
            description [list S [dict get $match description]]]
        set tags {}
        if {[dict exists $match tags]} {set tags [dict get $match tags]}
        dict set fields tags [list L [lmap tag $tags {list S $tag}]]
        if {[dict exists $match tier]} {
            dict set fields match_label [list S [lindex \
                {{Exact match} {Name match} {Name match} {Description match} {Tag match} {Similar name} {Similar description} {Similar tag}} \
                [dict get $match tier]]]
        }
        lappend cards [list M $fields]
    }
    return [list L $cards]
}

proc get_search_page_handler {ctx req} {
    set status 200
    set matches {}
    set message {}
    if {[catch {::recipe_search::request_query $req} query]} {
        set status 400
        set query {}
        set message {Use 1–255 letters, numbers, spaces, dots, underscores, plus signs or hyphens.}
    } else {
        if {[catch {::recipe_search::results $query} matches]} {return [::recipe_search::unavailable]}
    }
    set data [dict create title {S {Search packages}} query [list S $query] \
        is_search {BOOL 1} error [list S $message] result_count [list N [llength $matches]] \
        packages [::recipe_search::cards $matches]]
    return [::twebserver::build_response $status "text/html; charset=utf-8" \
        [::views::render packages.html.jinja $data]]
}
