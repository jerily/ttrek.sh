#
# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.
#


namespace eval ::request_validation {
    variable validators {}
    variable directory [file normalize [file join [file dirname [info script]] .. schemas]]
}

# Validate the request against its operation schema.
proc ::request_validation::check {name request} {
    variable validators
    set validator [validator $name]
    set normalized [::topenapi::from_twebserver $request]
    set result [$validator validate $normalized]
    if {![dict get $result valid]} {
        return -code error -errorcode {TTREK REQUEST INVALID} [dict get $result error]
    }
    return $normalized
}

# Return the validator for the selected request operation.
proc ::request_validation::validator {name} {
    variable validators
    if {![dict exists $validators $name]} {
        if {$name ni {search telemetry-collect registry-packages registry-plan telemetry-batch}} {error "Unknown request operation: $name"}
        package require topenapi 0.2.0
        variable directory
        set channel [open [file join $directory $name.json] r]
        try {dict set validators $name [::topenapi::compile [read $channel]]} finally {close $channel}
    }
    return [dict get $validators $name]
}
