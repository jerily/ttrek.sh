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

proc ::registry_metadata::resolve_scripts {scripts_typed directory} {
    lassign $scripts_typed type scripts
    if {$type ne "M"} {error "recipe scripts must be an object"}
    set result {}
    dict for {name script} $scripts {
        if {$name eq {}} {error "recipe script names must not be empty"}
        lassign $script type value
        if {$type eq "S"} {
            lappend result $name $script
            continue
        }
        if {$type ne "M" || ![dict exists $value file] ||
            [dict size $value] != 1 + [dict exists $value args] ||
            [lindex [dict get $value file] 0] ne "S"} {
            error "recipe scripts must have string bodies or a file reference with optional args"
        }
        set presets {}
        if {[dict exists $value args]} {
            lassign [dict get $value args] args_type args
            if {$args_type ne "L"} {error "recipe script args must be an array of strings"}
            foreach arg $args {
                lassign $arg arg_type arg_value
                if {$arg_type ne "S"} {error "recipe script args must be an array of strings"}
                append presets " '" [string map [list ' {'"'"'}] $arg_value] "'"
            }
        }
        set filename [lindex [dict get $value file] 1]
        if {![regexp {^[A-Za-z0-9._+-]+$} $filename] || $filename in {. ..}} {
            error "Invalid recipe script filename"
        }
        set path [file join $directory $filename]
        if {![file exists $path] || [file type $path] ne "file"} {
            error "Recipe script must be a regular file in its recipe directory: $path"
        }
        set fp [open $path rb]
        try {
            set body [encoding convertfrom utf-8 [read $fp]]
        } finally {
            close $fp
        }
        if {[string first \u0000 $body] >= 0} {error "Recipe script must not contain NUL bytes"}
        if {$presets ne {}} {
            # Return a self-contained shell body with literal presets before runtime arguments.
            set position 0
            if {[string range $body 0 1] eq "#!"} {
                set position [string first \n $body]
                if {$position < 0} {
                    append body \n
                    set position [string length $body]
                } else {incr position}
            }
            set body "[string range $body 0 $position-1]set --$presets \"\$@\"\n[string range $body $position end]"
        }
        lappend result $name [list S $body]
    }
    return [list M $result]
}

# Store a complete, self-contained recipe. HTTP handlers never open source files.
proc ::registry_metadata::payload {spec path} {
    set recipe [lindex [::tjson::to_typed $spec] 1]
    foreach field {dependencies build scripts} {
        if {![dict exists $recipe $field]} {dict set recipe $field {M {}}}
        if {[lindex [dict get $recipe $field] 0] ne "M"} {
            error "$field must be an object in $path"
        }
    }
    dict set recipe scripts [resolve_scripts [dict get $recipe scripts] [file dirname $path]]
    set patches {}
    foreach patch [lsort -ascii [glob -nocomplain -types f -directory [file dirname $path] *.diff]] {
        if {[file type $patch] ne "file"} {error "Patch must be a regular file: $patch"}
        set channel [open $patch rb]
        try {set bytes [read $channel]} finally {close $channel}
        dict set patches [file tail $patch] [list S [binary encode base64 -maxlen 0 $bytes]]
    }
    return [dict create recipe [::tjson::typed_to_json [list M $recipe]] \
        patches [::tjson::typed_to_json [list M $patches]]]
}
