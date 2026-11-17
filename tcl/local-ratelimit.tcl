#
# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.
#

# In-process store for local Lambda mocks. Production uses tratelimit's Valkey store.
namespace eval ::tratelimit::middleware::localstore {
    variable requests {}
}

# Initialize the local rate-limit store.
proc ::tratelimit::middleware::localstore::init {config} {
    variable requests {}
}

# Return requests made for the caller.
proc ::tratelimit::middleware::localstore::get_requests_made {key start end} {
    variable requests
    set recent {}
    if {[dict exists $requests $key]} {
        foreach timestamp [dict get $requests $key] {
            if {$timestamp > $start && $timestamp <= $end} {lappend recent $timestamp}
        }
    }
    dict set requests $key $recent
    return [llength $recent]
}

# Record a request and return the local rate-limit decision.
proc ::tratelimit::middleware::localstore::add_request {key start now} {
    variable requests
    dict lappend requests $key $now
}
