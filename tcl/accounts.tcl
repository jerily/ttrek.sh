#
# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.
#

namespace eval ::accounts {
    variable store {}
    variable mount {}
    variable handles {}
}

# Create persistent development keys atomically so local workers share one identity.
proc ::accounts::local_keys {directory} {
    package require tink
    package require tjson
    package require twebserver
    file mkdir $directory
    set path [file join $directory account-keys.json]
    if {![file exists $path]} {
        set values [dict create aead_keyset [list S [::tink::aead::create_keyset AES256_GCM]] \
            mac_keyset [list S [::tink::mac::create_keyset HMAC_SHA256]] \
            email_hash_salt [list S [binary encode hex [::twebserver::random_bytes 32]]]]
        set channel [file tempfile temporary [file join $directory .account-keys-]]
        try {
            file attributes $temporary -permissions 0600
            chan configure $channel -encoding utf-8
            puts $channel [::tjson::typed_to_json [list M $values]]
            close $channel
            set channel {}
            # Hard linking publishes a complete file without replacing a winner.
            if {[catch {file link -hard $path $temporary} message opts] && ![file exists $path]} {
                return -options $opts $message
            }
        } finally {
            if {$channel ne {}} {close $channel}
            file delete $temporary
        }
    }
    set channel [open $path r]
    try {return [::tjson::json_to_simple [read $channel]]} finally {close $channel}
}

# Mount accounts on the worker's existing SQL connection and site templates.
proc ::accounts::mount {router settings templates} {
    variable store
    variable mount
    variable handles
    package require web-user 0.4.0
    foreach handle $handles {::tink::unregister_keyset $handle}
    set handles {}
    set config [dict get $settings account]
    set policy [dict get $config policy]
    try {
        foreach {name key} {aead aead_keyset mac mac_keyset} {
            set handle [::tink::register_keyset [dict get $config keys $key]]
            lappend handles $handle
            dict set policy $name $handle
        }
        dict set policy email_hash_salt [dict get $config keys email_hash_salt]
        set store [::web::user::create -connection [dict get $settings content_connection] -config $policy]
        set display [dict merge [dict get $config display] [dict create \
            master_template [dict get $templates account-master.html.jinja] \
            templates [dict create master.html.jinja [dict get $templates master.html.jinja]]]]
        set mount [::web::user::mount $router -store $store -config $display]
    } on error {message options} {
        foreach handle $handles {::tink::unregister_keyset $handle}
        set handles {}
        set store {}
        return -options $options $message
    }
    return $mount
}

# Adapt verified account IDs to treqmon's session field, counting each user once.
proc ::accounts::monitor_enter {context request} {
    variable mount
    dict unset request session
    set user [::web::user::current_user $mount $request $context]
    if {$user ne {}} {
        dict set request session [dict create loggedin true id [dict get $user id]]
    }
    return $request
}

# Fill the shared layout from this request's session, including a newly rotated cookie.
proc ::accounts::navigation {request response context} {
    variable mount
    set marker {<!-- ttrek-account-navigation -->}
    if {[string first $marker [dict get $response body]] < 0} {return $response}
    set html {}
    if {[dict exists [::site::config] account]} {
        set prefix [dict get $mount -prefix]
        set cookie [::responses::header $response Set-Cookie]
        if {[string match [dict get $mount -cookie]=* $cookie]} {
            ::responses::set_header request Cookie [lindex [split $cookie {;}] 0]
        }
        set signedIn [expr {[::web::user::current_user $mount $request $context] ne {}}]
        set selected [expr {[dict get $request path] eq $prefix || [string match $prefix/* [dict get $request path]]}]
        set target [expr {$selected ? [::web::user::requested_return_to $request] : [::web::user::request_target $request]}]
        set html [::views::render account-navigation.html.jinja [dict create \
            signed_in [list BOOL $signedIn] selected [list BOOL $selected] prefix [list S $prefix] \
            return_query [list S [::web::user::return_query $target]]]]
        ::responses::set_header response Cache-Control no-store
        ::responses::set_header response ETag {}
    }
    dict set response body [string map [list $marker $html] [dict get $response body]]
    return $response
}

# Run a bounded account cleanup pass from a private scheduled maintenance task.
proc ::accounts::prune {{batch 500}} {
    variable store
    if {$store eq {}} {error "Accounts are not configured in this worker"}
    ::web::user::prune $store $batch
}

# Temporary upgrade: encrypt bare bcrypt hashes through November 16, 2026
# (America/New_York). Repeated initialization never re-encrypts ciphertext.
proc ::accounts::migrate_password_hashes {} {
    set deadline [clock scan {2026-11-17 00:00:00} -format {%Y-%m-%d %H:%M:%S} -timezone :America/New_York]
    if {[clock seconds] >= $deadline} {return {}}
    variable store
    if {$store eq {}} {error "Accounts are not configured in this worker"}
    set connection [dict get $store -connection]
    set counts {web_user_users 0 web_user_registrations 0}
    ::tpersist::db_transaction $connection {
        foreach table [dict keys $counts] {
            set query [::tpersist::db_where [::tpersist::db_select $table] [::web::user::predicate $store {}]]
            ::tpersist::db_foreach_row $connection row $query {
                set hash [dict get $row password]
                if {![regexp {^\$2[aby]\$(0[4-9]|[12][0-9]|3[01])\$[./A-Za-z0-9]{53}$} $hash]} continue
                set uid [dict get $row id]
                set encrypted [::web::user::seal $store $hash [list password-hash $uid]]
                # Do not overwrite a password changed since this row was read.
                if {[::web::user::update $store $table [dict create id $uid password $hash] \
                        [dict create password $encrypted]] != 1} {
                    error "Account credentials changed during initialization; retry"
                }
                dict incr counts $table
            }
        }
    }
    return $counts
}
