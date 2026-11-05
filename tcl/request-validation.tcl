package require topenapi 0.1.0

namespace eval ::request_validation {
    variable validators {}
}

# Cache parsed operation fragments per worker, beside the application sources.
foreach name {search telemetry-collect} {
    set channel [open [file join [file dirname [info script]] .. schemas $name.json] r]
    try {
        set validator [::topenapi::compile [read $channel]]
    } finally {
        close $channel
    }
    dict set ::request_validation::validators $name $validator
}
unset name channel validator

proc ::request_validation::check {name request} {
    variable validators
    set normalized [::topenapi::from_twebserver $request]
    set result [[dict get $validators $name] validate $normalized]
    if {![dict get $result valid]} {
        return -code error -errorcode {TTREK REQUEST INVALID} [dict get $result error]
    }
    return $normalized
}
