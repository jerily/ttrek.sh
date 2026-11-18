# SPDX-License-Identifier: MIT
# Templates are resolved by name, with one parsed cache per composition.
namespace eval ::views {
    variable templates {}
    variable environments {}
}

proc ::views::init {directory {validate true}} {
    variable template_directory [file normalize $directory]
    variable templates {}
    variable environments
    dict for {key command} $environments {catch {$command destroy}}
    set environments {}
    ::assets::load [file dirname $directory]
    set fields {}
    foreach path [concat [dict keys $::assets::manifest] {/favicon.ico /assets/favicon.svg /request-monitor/_assets/charts.js}] {
        dict set fields $path [list S [::assets::url $path]]
    }
    variable asset_urls [::tjson::typed_to_json [list M $fields]]
    if {$validate} {
        package require jinja2 0.2.0
        foreach path [glob -directory $directory *.html.jinja] {load [file tail $path]}
        dict for {name text} $templates {::jinja2::validate $text -templates $templates -path $name}
    }
}

# Both template names and files must remain inside their trusted asset directory.
proc ::views::read_template {directory name} {
    if {![regexp {^[A-Za-z0-9_./-]+\.html\.jinja$} $name] ||
        [file pathtype $name] ne "relative" || [regexp {(^|/)(\.?\.?)(/|$)} $name]} {
        error "Invalid template name: $name"
    }
    set path $directory
    foreach part [split $name /] {
        set path [file join $path $part]
        if {[file type $path] eq "link"} {error "Template symlinks are not supported: $name"}
    }
    set channel [open $path r]
    try {chan configure $channel -encoding utf-8; read $channel} finally {close $channel}
}

proc ::views::load {name} {
    variable template_directory
    variable templates
    variable asset_urls
    if {[dict exists $templates $name]} {return [dict get $templates $name]}
    set text [read_template $template_directory $name]
    foreach {reference asset} [regexp -all -inline {asset_urls\['([^']+)'\]} $text] {::assets::url $asset}
    if {![regexp {\{%[-+]?\s*extends\M} $text]} {set text "{% set asset_urls = $asset_urls %}$text"}
    dict set templates $name $text
    return $text
}

proc ::views::package_info {kind} {
    switch -- $kind {
        account {return {web-user ::web::user account-master.html.jinja}}
        forum {return {web-forum ::web::forum forum-master.html.jinja}}
        wiki {return {web-static-wiki ::web::static::wiki docs-master.html.jinja}}
        blog {return {web-static-blog ::web::static::blog blog-master.html.jinja}}
        monitor {
            set master request-monitor-master.html.jinja
            if {[dict exists [::site::config] request_monitor master_template]} {
                set master [dict get [::site::config] request_monitor master_template]
            }
            return [list treqmon ::treqmon $master]
        }
        default {error "Unknown template composition: $kind"}
    }
}

proc ::views::package_load {kind name} {
    lassign [package_info $kind] package ns master
    if {$name eq "page.html.jinja"} {return [load $master]}
    if {$name eq "master.html.jinja"} {return [load $name]}
    package require ${package}::routes 1.0
    read_template [set ${ns}::template_directory] $name
}

proc ::views::environment {kind {overrides {}}} {
    variable environments
    set key [list $kind $overrides]
    if {![dict exists $environments $key]} {
        package require jinja2 0.2.0
        if {$kind eq "site"} {set loader ::views::load} else {set loader [list ::views::package_load $kind]}
        dict set environments $key [::jinja2::environment -loader $loader -templates $overrides]
    }
    dict get $environments $key
}

proc ::views::render {name fields} {
    stamp_year [[environment site] render $name [::tjson::typed_to_json [list M $fields]]]
}

proc ::views::render_package {kind name json {overrides {}}} {
    [environment $kind $overrides] render $name $json
}

proc ::views::mount_settings {kind} {
    dict create validate_templates false template_renderer [list ::views::render_package $kind]
}

proc ::views::names {directory {prefix {}}} {
    set result {}
    foreach path [lsort [glob -nocomplain -directory $directory *]] {
        set name $prefix[file tail $path]
        if {[file type $path] eq "directory"} {
            lappend result {*}[names $path $name/]
        } elseif {[string match *.html.jinja $name]} {lappend result $name}
    }
    return $result
}

# Eager mode uses the same loader/cache; loading does not render or access SQL.
proc ::views::prewarm {} {
    variable template_directory
    set env [environment site]
    foreach name [names $template_directory] {$env load $name}
    set kinds {wiki blog monitor}
    if {[dict exists [::site::config] account]} {lappend kinds account forum}
    foreach kind $kinds {
        lassign [package_info $kind] package ns master
        package require ${package}::routes 1.0
        set env [environment $kind]
        foreach name [names [set ${ns}::template_directory]] {$env load $name}
        $env load master.html.jinja
    }
}

# Packaging always checks all site templates and all package/layout compositions.
proc ::views::validate_all {{monitorMaster request-monitor-master.html.jinja}} {
    variable templates
    variable template_directory
    package require jinja2 0.2.0
    foreach name [names $template_directory] {load $name}
    dict for {name text} $templates {::jinja2::validate $text -templates $templates -path $name}
    foreach package {web-user web-forum web-static-wiki web-static-blog treqmon} {package require $package}
    foreach {provider master} [list \
        ::web::user::prepare_templates account-master.html.jinja \
        ::web::forum::prepare_templates forum-master.html.jinja \
        ::web::static::wiki::prepare_templates docs-master.html.jinja \
        ::web::static::blog::prepare_templates blog-master.html.jinja \
        ::treqmon::view::prepare_templates $monitorMaster] {
        $provider [dict create validate_templates true master_template [dict get $templates $master] \
            templates [dict create master.html.jinja [dict get $templates master.html.jinja]]]
    }
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
