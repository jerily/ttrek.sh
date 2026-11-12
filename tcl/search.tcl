package require tjson
source [file join [file dirname [info script]] registry-metadata.tcl]
package require ttrie 0.2.0
package require ttrigrams 0.2.0

namespace eval ::recipe_search {
    variable entries
    variable documents
}

proc ::recipe_search::fold {text} {
    string map {A a B b C c D d E e F f G g H h I i J j K k L l M m N n O o P p Q q R r S s T t U u V v W w X x Y y Z z} $text
}

proc ::recipe_search::valid_name {name} {
    expr {[string length $name] >= 1 && [string length $name] <= 255 &&
          $name ni {. ..} && [regexp {^[A-Za-z0-9._+-]+$} $name]}
}

proc ::recipe_search::query {text} {
    if {[string length $text] > 255 || ![regexp {^[A-Za-z0-9._+ -]+$} $text]} {
        error "Invalid search query"
    }
    set text [fold [string trim $text " "]]
    if {$text in {{} . ..}} {error "Invalid search query"}
    return $text
}

# Snapshot metadata uses typed JSON so malformed shapes cannot become Tcl data.
proc ::recipe_search::snapshot_value {value type} {
    if {[llength $value] != 2 || [lindex $value 0] ne $type} {error "Invalid search snapshot metadata"}
    return [lindex $value 1]
}

proc ::recipe_search::load {path} {
    variable entries
    variable documents
    if {![file isfile $path]} {error "Search snapshot is missing; run the build-search script"}
    set channel [open $path r]
    try {
        fconfigure $channel -encoding utf-8
        ::tjson::parse [read $channel] snapshot
    } finally {close $channel}
    set fields [snapshot_value [::tjson::to_typed $snapshot] M]
    if {[snapshot_value [dict get $fields format] N] ni {1 2}} {error "Unsupported search snapshot format"}
    set catalog {}
    dict for {name value} [snapshot_value [dict get $fields entries] M] {
        set data [snapshot_value $value M]
        set normalized [snapshot_value [dict get $data normalized] S]
        set description [snapshot_value [dict get $data description] S]
        if {![valid_name $name] || $normalized ne [fold $name]} {error "Invalid search snapshot package"}
        set tags {}
        if {[dict exists $data tags]} {set tags [::registry_metadata::tags [dict get $data tags] $path]}
        dict set catalog $name [dict create normalized $normalized description $description tags $tags]
    }
    set docs {}
    foreach value [snapshot_value [dict get $fields documents] L] {
        set pair [snapshot_value $value L]
        if {[llength $pair] ni {2 3}} {error "Invalid search snapshot document"}
        set name [snapshot_value [lindex $pair 0] S]
        set description [snapshot_value [lindex $pair 1] S]
        if {![dict exists $catalog $name]} {error "Unknown search snapshot package"}
        set field description
        if {[llength $pair] == 3} {
            set field [snapshot_value [lindex $pair 2] S]
            if {$field ne "tags"} {error "Invalid search snapshot field"}
        }
        lappend docs [list $name $description $field]
    }
    # Publish both loaded indexes and their metadata together, after validation.
    try {
        ::ttrie::load ::recipe_search::next_names \
            [binary decode base64 -strict [snapshot_value [dict get $fields names] S]]
        ::ttrigrams::load ::recipe_search::next_descriptions \
            [binary decode base64 -strict [snapshot_value [dict get $fields descriptions] S]]
        if {[next_descriptions count] != [llength $docs]} {error "Search snapshot document count mismatch"}
        dict for {name data} $catalog {
            if {![next_names contains [dict get $data normalized]]} {error "Search snapshot package is not indexed"}
        }
        foreach command {index descriptions} {
            if {[llength [info commands ::recipe_search::$command]]} {::recipe_search::$command destroy}
        }
        rename ::recipe_search::next_names ::recipe_search::index
        rename ::recipe_search::next_descriptions ::recipe_search::descriptions
        set entries $catalog
        set documents $docs
    } finally {
        foreach command {next_names next_descriptions} {
            if {[llength [info commands ::recipe_search::$command]]} {::recipe_search::$command destroy}
        }
    }
}

# Build once per catalog change, keeping native indexes in each worker.
# Database rows are ordered and contain only versions published by registry sync.
proc ::recipe_search::load_rows {rows} {
    variable entries
    variable documents
    variable catalog_rows
    set versions {}
    foreach row $rows {
        set name [dict get $row name]
        set version [dict get $row version]
        if {![valid_name $name] || ![valid_name $version]} {continue}
        dict set versions $name $version $row
    }
    set catalog {}
    set docs {}
    set texts {}
    set names {}
    foreach name [lsort -ascii [dict keys $versions]] {
        set descriptions {}
        set tags {}
        dict for {version row} [dict get $versions $name] {
            set description [dict get $row description]
            if {$description ne {}} {lappend descriptions $description}
            lappend tags {*}[dict get $row tags]
        }
        set descriptions [lsort -ascii -unique $descriptions]
        set tags [lsort -ascii -unique $tags]
        lappend names [fold $name]
        dict set catalog $name [dict create normalized [fold $name] \
            description [lindex $descriptions 0] tags $tags versions [dict get $versions $name]]
        foreach text $descriptions {
            lappend docs [list $name $text description]
            lappend texts [fold $text]
        }
        foreach tag $tags {
            lappend docs [list $name $tag tags]
            lappend texts [fold $tag]
        }
    }
    try {
        ::ttrie::create ::recipe_search::next_names $names
        ::ttrigrams::create ::recipe_search::next_descriptions $texts
        foreach command {index descriptions} {
            if {[llength [info commands ::recipe_search::$command]]} {::recipe_search::$command destroy}
        }
        rename ::recipe_search::next_names ::recipe_search::index
        rename ::recipe_search::next_descriptions ::recipe_search::descriptions
        set entries $catalog
        set documents $docs
        set catalog_rows $rows
    } finally {
        foreach command {next_names next_descriptions} {
            if {[llength [info commands ::recipe_search::$command]]} {::recipe_search::$command destroy}
        }
    }
}

proc ::recipe_search::refresh {} {
    variable catalog_rows
    set config [::site::config]
    if {[dict exists $config telemetry_thread_id]} {
        set rows [thread::send [dict get $config telemetry_thread_id] {::telemetry::registry_catalog}]
    } else {set rows [::telemetry::registry_catalog]}
    if {![info exists catalog_rows] || $rows ne $catalog_rows} {load_rows $rows}
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
        dict set found $name [dict create name $name description [dict get $data description] tags [dict get $data tags] \
            tier $tier distance $distance negative_coverage 0 unmatched $unmatched query_trigrams 0 shared_trigrams 0]
    }
    foreach match [descriptions search $text $limit] {
        lassign [lindex $documents [dict get $match document]] name description field
        set distance [dict get $match distance]
        set shared [dict get $match shared_trigrams]
        set total [dict get $match query_trigrams]
        set tier [expr {($distance == 0 ? 3 : 6) + ($field eq "tags")}]
        if {$field eq "tags"} {set description [dict get $entries $name description]}
        set candidate [dict create name $name description $description tags [dict get $entries $name tags] tier $tier distance $distance \
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
    ::recipe_search::refresh
    foreach match [::recipe_search::search $query] {
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
    ::recipe_search::refresh
    set suggestions {}
    foreach match [lrange [::recipe_search::search $query] 0 7] {
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
        ::recipe_search::refresh
        set matches [::recipe_search::search $query]
    }
    set data [dict create title {S {Search packages}} query [list S $query] \
        is_search {BOOL 1} error [list S $message] result_count [list N [llength $matches]] \
        packages [::recipe_search::cards $matches]]
    return [::twebserver::build_response $status "text/html; charset=utf-8" \
        [::views::render packages.html.jinja $data]]
}
