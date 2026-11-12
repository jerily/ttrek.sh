namespace eval ::registry_metadata {}

# Tags are optional metadata; callers use an empty list when the field is absent.
proc ::registry_metadata::tags {typed {path recipe}} {
    if {[lindex $typed 0] ne "L"} {error "tags must be an array of strings in $path"}
    set result {}
    foreach item [lindex $typed 1] {
        lassign $item type text
        if {$type ne "S"} {error "tags must be an array of strings in $path"}
        if {$text eq {} || [string length [encoding convertto utf-8 $text]] > 255 ||
            [regexp {[\x00-\x1f\x7f]} $text]} {
            error "tags must contain nonempty single-line strings of at most 255 bytes in $path"
        }
        lappend result $text
    }
    return [lsort -ascii -unique $result]
}

