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
    set rows {}
    foreach path [lsort -ascii [glob -nocomplain -type f -directory $directory */*/ttrek.json]] {
        set version [file tail [file dirname $path]]
        set name [file tail [file dirname [file dirname $path]]]
        if {![valid_name $name] || ![valid_name $version]} continue
        lappend rows [dict merge [dict create name $name version $version] [metadata $path]]
    }
    set snapshot [snapshot_json [build_snapshot [snapshot_inputs $rows]]]
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
    return $destination
}
