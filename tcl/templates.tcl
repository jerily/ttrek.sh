#
# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.
#

package require Tcl 9.1
package require jinja2 0.1.0
package require tjson

namespace eval ::views {
    variable templates {}
}

# Load trusted application templates once in each worker interpreter.
proc ::views::init {directory {validate true}} {
    variable templates
    ::assets::load [file dirname $directory]
    set fields {}
    foreach path [concat [dict keys $::assets::manifest] {/favicon.ico /assets/favicon.svg /request-monitor/_assets/charts.js}] {
        dict set fields $path [list S [::assets::url $path]]
    }
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
    if {$validate} {
        dict for {name template} $templates {
            ::jinja2::validate $template -templates $templates -path $name
        }
    }
}

# Packaging validates the same compositions as runtime mounts, without SQL,
# account keys, AWS clients or middleware connections. Always validate here,
# even when the build environment is PROD.
proc ::views::validate_all {{monitorMaster request-monitor-master.html.jinja}} {
    variable templates
    dict for {name template} $templates {
        ::jinja2::validate $template -templates $templates -path $name
    }
    package require web-user 0.7.1
    package require web-forum 0.3.3
    foreach {provider master} [list \
        ::web::user::prepare_templates account-master.html.jinja \
        ::web::forum::prepare_templates forum-master.html.jinja \
        ::web::static::wiki::prepare_templates docs-master.html.jinja \
        ::web::static::blog::prepare_templates blog-master.html.jinja \
        ::treqmon::view::prepare_templates $monitorMaster] {
        $provider [dict create validate_templates true \
            master_template [dict get $templates $master] \
            templates [dict create master.html.jinja [dict get $templates master.html.jinja]]]
    }
}

# Each field has a tjson type tag; never infer arrays/objects from Tcl strings.
proc ::views::render {name fields} {
    variable templates
    return [stamp_year [::jinja2::render [dict get $templates $name] \
        [::tjson::typed_to_json [list M $fields]] -templates $templates -path $name]]
}

# Content packages render their own JSON contexts. Fill the host layout's
# trusted marker after rendering so every page uses the clock on each request.
proc ::views::stamp_year {html} {
    string map [list {<!-- ttrek-current-year -->} [clock format [clock seconds] -format %Y]] $html
}

# Encode a sequence as explicit JSON strings.
proc ::views::strings {values} {
    return [list L [lmap value $values {list S $value}]]
}

# Encode platform totals as typed JSON table rows.
proc ::views::download_stats {rows} {
    set values {}
    foreach row $rows {
        lassign $row platform downloads
        lappend values [list L [list [list S $platform] [list N $downloads]]]
    }
    return [list L $values]
}

# Encode installation totals as typed JSON table rows.
proc ::views::platform_stats {rows} {
    set values {}
    foreach row $rows {
        lassign $row platform total success failure
        lappend values [list L [list [list S $platform] [list N $total] \
            [list N $success] [list N $failure]]]
    }
    return [list L $values]
}
