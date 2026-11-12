# Build-only registry reader. Runtime workers source search.tcl and call load.
source [file join [file dirname [info script]] search.tcl]

proc ::recipe_search::metadata {path} {
    set channel [open $path r]
    try {
        fconfigure $channel -encoding utf-8
        ::tjson::parse [read $channel] spec
    } finally {close $channel}
    if {![::tjson::is_object $spec]} {error "Invalid JSON object in $path"}
    set text {}
    if {[::tjson::has_object_item $spec description]} {
        set item [::tjson::get_object_item $spec description]
        if {![::tjson::is_string $item]} {error "description must be a string in $path"}
        set text [::tjson::get_valuestring $item]
        if {[string length [encoding convertto utf-8 $text]] > 4096 || [regexp {[\x00-\x1f\x7f]} $text]} {
            error "description must be a single line of at most 4096 bytes in $path"
        }
    }
    set tags {}
    if {[::tjson::has_object_item $spec tags]} {
        set tags [::registry_metadata::tags [::tjson::to_typed [::tjson::get_object_item $spec tags]] $path]
    }
    return [dict create description $text tags $tags]
}

proc ::recipe_search::build {directory destination} {
    if {![file isdirectory $directory]} {error "Search registry directory does not exist"}
    set catalog {}
    set docs {}
    set texts {}
    set names {}
    foreach path [lsort -ascii [glob -nocomplain -type d -directory $directory *]] {
        set name [file tail $path]
        if {![valid_name $name]} {continue}
        set descriptions {}
        set package_tags {}
        set has_recipe 0
        foreach version [lsort -ascii [glob -nocomplain -type d -directory $path *]] {
            set recipe [file join $version ttrek.json]
            if {[valid_name [file tail $version]] && [file isfile $recipe]} {
                set has_recipe 1
                set data [metadata $recipe]
                set text [dict get $data description]
                lappend package_tags {*}[dict get $data tags]
                if {$text ne {}} {lappend descriptions $text}
            }
        }
        if {!$has_recipe} {continue}
        set descriptions [lsort -ascii -unique $descriptions]
        set package_tags [lsort -ascii -unique $package_tags]
        set normalized [fold $name]
        lappend names $normalized
        dict set catalog $name [dict create normalized $normalized description [lindex $descriptions 0] tags $package_tags]
        foreach text $descriptions {
            lappend docs [list $name $text]
            lappend texts [fold $text]
        }
        foreach tag $package_tags {
            lappend docs [list $name $tag tags]
            lappend texts [fold $tag]
        }
    }
    # Serialize the built structures, never a list of inputs to reindex at startup.
    try {
        ::ttrie::create ::recipe_search::build_names $names
        ::ttrigrams::create ::recipe_search::build_descriptions $texts
        set packages {}
        dict for {name data} $catalog {
            dict set packages $name [list M [dict create \
                normalized [list S [dict get $data normalized]] \
                description [list S [dict get $data description]] \
                tags [list L [lmap tag [dict get $data tags] {list S $tag}]]]]
        }
        set documents [lmap doc $docs {list L [lmap value $doc {list S $value}]}]
        set snapshot [::tjson::typed_to_json [list M [dict create format {N 2} \
            entries [list M $packages] documents [list L $documents] \
            names [list S [binary encode base64 -maxlen 0 [build_names serialize]]] \
            descriptions [list S [binary encode base64 -maxlen 0 [build_descriptions serialize]]]]]]
        file mkdir [file dirname $destination]
        set channel [file tempfile temporary [file join [file dirname $destination] .search-]]
        try {
            fconfigure $channel -encoding utf-8 -translation lf
            puts $channel $snapshot
            close $channel
            set channel {}
            file attributes $temporary -permissions 0644
            file rename -force $temporary $destination
        } finally {
            if {$channel ne {}} {close $channel}
            file delete -force $temporary
        }
    } finally {
        foreach command {build_names build_descriptions} {
            if {[llength [info commands ::recipe_search::$command]]} {::recipe_search::$command destroy}
        }
    }
    return $destination
}
