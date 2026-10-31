package require Tcl 9.1
package require jinja2 0.1.0
package require tjson

namespace eval ::views {
    variable templates {}
}

# Load trusted application templates once in each worker interpreter.
proc ::views::init {directory} {
    variable templates
    set templates {}
    foreach path [glob -directory $directory *.html.jinja] {
        set channel [open $path r]
        try {
            chan configure $channel -encoding utf-8
            dict set templates [file tail $path] [read $channel]
        } finally {
            close $channel
        }
    }
    dict for {name template} $templates {
        ::jinja2::validate $template -templates $templates -path $name
    }
}

# Each field has a tjson type tag; never infer arrays/objects from Tcl strings.
proc ::views::render {name fields} {
    variable templates
    dict set fields pagetitle {S {ttrek: registry, website, and command-line interface}}
    return [::jinja2::render [dict get $templates $name] \
        [::tjson::typed_to_json [list M $fields]] -templates $templates -path $name]
}

proc ::views::strings {values} {
    return [list L [lmap value $values {list S $value}]]
}

proc ::views::platform_stats {rows} {
    set values {}
    foreach row $rows {
        lassign $row platform total success failure
        lappend values [list L [list [list S $platform] [list N $total] \
            [list N $success] [list N $failure]]]
    }
    return [list L $values]
}
