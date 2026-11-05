package require ttrie 0.1.1
package require ttrigrams 0.1.0

namespace eval ::recipe_search {
    variable entries {}
    variable documents {}
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

proc ::recipe_search::description {path} {
    set channel [open $path r]
    try {::tjson::parse [read $channel] spec} finally {close $channel}
    if {![::tjson::is_object $spec]} {error "Invalid JSON object in $path"}
    if {![::tjson::has_object_item $spec description]} {return {}}
    set item [::tjson::get_object_item $spec description]
    if {![::tjson::is_string $item]} {error "description must be a string in $path"}
    set text [::tjson::get_valuestring $item]
    if {[string length [encoding convertto utf-8 $text]] > 4096 || [regexp {[\x00-\x1f\x7f]} $text]} {
        error "description must be a single line of at most 4096 bytes in $path"
    }
    return $text
}

proc ::recipe_search::init {directory} {
    variable entries
    variable documents
    if {![file isdirectory $directory]} {error "Search registry directory does not exist"}
    set catalog {}
    set docs {}
    set texts {}
    set names {}
    foreach path [lsort -ascii [glob -nocomplain -type d -directory $directory *]] {
        set name [file tail $path]
        if {![valid_name $name]} {continue}
        set descriptions {}
        set has_recipe 0
        foreach version [lsort -ascii [glob -nocomplain -type d -directory $path *]] {
            set recipe [file join $version ttrek.json]
            if {[valid_name [file tail $version]] && [file isfile $recipe]} {
                set has_recipe 1
                set text [description $recipe]
                if {$text ne {}} {lappend descriptions $text}
            }
        }
        if {!$has_recipe} {continue}
        set descriptions [lsort -ascii -unique $descriptions]
        set normalized [fold $name]
        lappend names $normalized
        dict set catalog $name [dict create normalized $normalized description [lindex $descriptions 0]]
        foreach text $descriptions {
            lappend docs [list $name $text]
            lappend texts [fold $text]
        }
    }
    # Install both indexes together; a failed refresh leaves the old snapshot usable.
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
    } finally {
        foreach command {next_names next_descriptions} {
            if {[llength [info commands ::recipe_search::$command]]} {::recipe_search::$command destroy}
        }
    }
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
        set tier 6
        set distance 0
        set unmatched 0
        if {$normalized eq $text} {set tier 0
        } elseif {[string first $text $normalized] == 0} {set tier 1
        } elseif {[string first $text $normalized] >= 0} {set tier 2
        } elseif {[dict exists $fuzzy $normalized]} {
            set tier 4
            set distance [dict get $fuzzy $normalized]
        }
        if {$tier in {1 2}} {set unmatched [expr {[string length $name] - [string length $text]}]}
        dict set found $name [dict create name $name description [dict get $data description] \
            tier $tier distance $distance negative_coverage 0 unmatched $unmatched query_trigrams 0 shared_trigrams 0]
    }
    foreach match [descriptions search $text $limit] {
        lassign [lindex $documents [dict get $match document]] name description
        set distance [dict get $match distance]
        set shared [dict get $match shared_trigrams]
        set total [dict get $match query_trigrams]
        set tier [expr {$distance == 0 ? 3 : 5}]
        set candidate [dict create name $name description $description tier $tier distance $distance \
            negative_coverage [expr {-$shared}] unmatched 0 query_trigrams $total shared_trigrams $shared]
        if {[compare $candidate [dict get $found $name]] < 0} {dict set found $name $candidate}
    }
    set results {}
    foreach match [lsort -command ::recipe_search::compare [dict values $found]] {
        if {[dict get $match tier] < 6} {lappend results $match}
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
    foreach match [::recipe_search::search $query] {
        set tier [dict get $match tier]
        set kind [lindex {exact prefix substring description fuzzy description-fuzzy} $tier]
        set total [dict get $match query_trigrams]
        set fields [dict create name [list S [dict get $match name]] \
            description [list S [dict get $match description]] match [list S $kind]]
        if {$tier ni {1 2}} {dict set fields distance [list N [dict get $match distance]]}
        if {$total} {dict set fields coverage [list N [expr {double([dict get $match shared_trigrams]) / $total}]]}
        lappend matches [list M $fields]
    }
    return [::twebserver::build_response 200 application/json \
        [::tjson::typed_to_json [list L $matches]]]
}
