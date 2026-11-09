package require Tcl 9.1
package require jinja2 0.1.0
package require tjson

namespace eval ::views {
    variable templates {}
}

# Load trusted application templates once in each worker interpreter.
proc ::views::init {directory} {
    variable templates
    ::assets::load [file dirname $directory]
    set fields {}
    dict for {path url} $::assets::manifest {dict set fields $path [list S $url]}
    set asset_urls [::tjson::typed_to_json [list M $fields]]
    set templates {}
    foreach path [glob -directory $directory *.html.jinja] {
        set channel [open $path r]
        try {
            chan configure $channel -encoding utf-8
            set template [read $channel]
            foreach {reference asset} [regexp -all -inline {asset_urls\['([^']+)'\]} $template] {
                ::assets::url $asset
            }
            # The root layout binds the manifest for inherited blocks, including
            # packages with independent contexts. Extending templates permit
            # only blocks at their root in jinja2-tcl.
            if {![regexp {\{%[-+]?\s*extends\M} $template]} {
                set template "{% set asset_urls = $asset_urls %}$template"
            }
            dict set templates [file tail $path] $template
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
    return [stamp_year [::jinja2::render [dict get $templates $name] \
        [::tjson::typed_to_json [list M $fields]] -templates $templates -path $name]]
}

# Content packages render their own JSON contexts. Fill the host layout's
# trusted marker after rendering so every page uses the clock on each request.
proc ::views::stamp_year {html} {
    string map [list {<!-- ttrek-current-year -->} [clock format [clock seconds] -format %Y]] $html
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
