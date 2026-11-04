package require ttrie 0.1.1

namespace eval ::recipe_search {}

proc ::recipe_search::valid_name {name} {
    expr {[string length $name] >= 1 && [string length $name] <= 255 &&
          $name ni {. ..} && [regexp {^[A-Za-z0-9._+-]+$} $name]}
}

proc ::recipe_search::init {directory} {
    if {![file isdirectory $directory]} {error "Search registry directory does not exist"}
    set names {}
    foreach path [glob -nocomplain -type d -directory $directory *] {
        set name [file tail $path]
        if {![valid_name $name]} {continue}
        foreach version [glob -nocomplain -type d -directory $path *] {
            if {[valid_name [file tail $version]] && [file isfile [file join $version ttrek.json]]} {
                lappend names $name
                break
            }
        }
    }
    # Interpreter-owned: build once at worker startup; requests only read it.
    ::ttrie::create ::recipe_search::index $names
}

proc get_search_handler {ctx req} {
    if {[catch {::twebserver::get_query_param $req q} query] || ![::recipe_search::valid_name $query]} {
        return [::twebserver::build_response 400 text/plain \
            "q must contain 1 to 255 ASCII letters, digits, '.', '_', '+' or '-'"]
    }
    set matches {}
    foreach match [::recipe_search::index search $query] {
        lappend matches [list M [list name [list S [dict get $match name]] \
            distance [list N [dict get $match distance]]]]
    }
    return [::twebserver::build_response 200 application/json \
        [::tjson::typed_to_json [list L $matches]]]
}
