# 
# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.
# 

namespace eval ::accounts {
    variable store {}
    variable mount {}
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
proc ::accounts::mount {router settings templates args} {
    set secret [::private_config::option {*}$args]
    variable store
    variable mount
    package require web-user 1.0.0
    if {$mount ne {}} {::web::user::release $mount}
    set mount {}; set store {}
    set config [dict get $settings account]
    ::app_config::load_session_backend [dict get $config policy]
    set display [dict merge [dict get $config display] [dict create \
        validate_templates [::site::validate_templates] \
        master_template [dict get $templates account-master.html.jinja] \
        templates [dict create master.html.jinja [dict get $templates master.html.jinja]]]]
    dict set display assets_url [::assets::base_url /user/_assets]
    dict set display email_queue_callback ::accounts::email_queued
    set mount [::web::user::mount $router -connection [dict get $settings content_connection] \
        -policy [dict get $config policy] -config $display -secret_config $secret]
    set store [dict get $mount -store]
    return $mount
}

# Prepare account resources when a registered route or hook needs them.
proc ::accounts::prepare {settings args} {
    variable store
    variable mount
    package require web-user 1.0.0
    if {$mount ne {}} {::web::user::release $mount}
    set mount {}; set store {}
    set config [dict get $settings account]
    ::app_config::load_session_backend [dict get $config policy]
    set display [dict merge [dict get $config display] [::views::mount_settings account]]
    dict set display assets_url [::assets::base_url /user/_assets]
    dict set display email_queue_callback ::accounts::email_queued
    set mount [::web::user::prepare_mount -connection [dict get $settings content_connection] \
        -policy [dict get $config policy] -config $display -secret_config [::private_config::option {*}$args]]
    set store [dict get $mount -store]
    return $mount
}

proc ::accounts::ensure {} {
    variable mount
    if {$mount eq {}} {::site::service account}
    return $mount
}

proc ::accounts::has_cookie {request} {
    set names {}
    foreach pair [split [::responses::header $request Cookie] {;}] {
        lappend names [string trim [lindex [split $pair =] 0]]
    }
    if {[dict exists $request cookies]} {lappend names {*}[dict keys [dict get $request cookies]]}
    foreach name $names {
        if {[string match web_user_* $name] || [string match __Host-web_user_* $name]} {return true}
    }
    return false
}

# Wake the deployed Lambda alias asynchronously after SQS has accepted an email.
proc ::accounts::email_queued {queueUrl} {
    package require pure-tcl-aws-lambda 1.0.0
    set client [::aws::lambda::create [dict create region $::env(AWS_REGION)]]
    try {
        $client invoke_function "$::env(AWS_LAMBDA_FUNCTION_NAME):DEFAULT" \
            {{"source":"ttrek.patch","task":"task_process_email_queue"}} Event
    } finally {$client destroy}
}

# Adapt verified account IDs to treqmon's session field, counting each user once.
proc ::accounts::monitor_enter {context request} {
    variable mount
    dict unset request session
    if {![has_cookie $request]} {return $request}
    ensure
    set user [::web::user::current_user $mount $request $context]
    if {$user ne {}} {
        dict set request session [dict create loggedin true id [dict get $user id]]
    }
    return $request
}

# Check the live grant for protected monitor routes.
proc ::accounts::can_view_monitor {request context} {
    variable mount
    if {![dict exists [::site::config] account] || ![has_cookie $request]} {return 0}
    ensure
    ::web::user::authorize_permission $mount request_monitor.view $request $context view /request-monitor
}

proc ::accounts::monitor_authorize {context request} {
    set path [dict get $request path]
    if {($path eq "/request-monitor" || [string match /request-monitor/* $path]) &&
        ![can_view_monitor $request $context]} {
        return -code error -options [dict create statusCode 403 body Forbidden \
            headers {Content-Type text/plain Cache-Control no-store}]
    }
    return $request
}

proc ::accounts::dashboard {context request} {
    if {![dict exists [::site::config] account]} {return [get_catchall_handler $context $request]}
    set mount [ensure]
    set user [::web::user::current_user $mount $request $context]
    if {$user eq {}} {return [::web::user::sign_in_redirect $mount $request]}

    set grants [::web::user::permissions [dict get $mount -store] [dict get $user id]]
    if {"admin_dashboard.manage" ni $grants} {
        return [::web::user::response 403 Forbidden text/plain]
    }
    set html [::views::render admin-dashboard.html.jinja [dict create \
        title {S {Admin dashboard}} prefix [list S [dict get $mount -prefix]] \
        can_view_monitor [list BOOL [expr {"request_monitor.view" in $grants}]] \
        can_manage_users [list BOOL [expr {"users.manage" in $grants}]]]]
    return [::web::user::response 200 $html]
}

# Fill the shared layout from this request's session, including a newly rotated cookie.
proc ::accounts::navigation {request response context} {
    variable mount
    set marker {<!-- ttrek-account-navigation -->}
    if {[string first $marker [dict get $response body]] < 0} {return $response}
    set html {}
    if {[dict exists [::site::config] account]} {
        package require web-user::config 1.0
        set prefix [dict get [::site::config] account display prefix]
        set cookie [::responses::header $response Set-Cookie]
        if {$mount ne {} && [string match [dict get $mount -cookie]=* $cookie]} {
            ::responses::set_header request Cookie [lindex [split $cookie {;}] 0]
        }
        set user {}
        if {[has_cookie $request]} {
            ensure
            set user [::web::user::current_user $mount $request $context]
        }
        set selected [expr {[dict get $request path] eq $prefix || [string match $prefix/* [dict get $request path]]}]
        set dashboardMarker {<!-- ttrek-admin-dashboard-link -->}
        if {$selected && [string first $dashboardMarker [dict get $response body]] >= 0} {
            set link {}
            if {$user ne {} && [::web::user::has_permission [dict get $mount -store] [dict get $user id] admin_dashboard.manage]} {
                set link {<p class="account-dashboard-link"><a href="/admin">Admin dashboard</a></p>}
            }
            dict set response body [string map [list $dashboardMarker $link] [dict get $response body]]
        }
        set target [expr {$selected ? [::web::user::requested_return_to $request] : [::web::user::request_target $request]}]
        set html [::views::render account-navigation.html.jinja [dict create \
            signed_in [list BOOL [expr {$user ne {}}]] selected [list BOOL $selected] prefix [list S $prefix] \
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

# Called only by the explicit private maintenance task, never by a request or
# worker startup. Configuration is the source of truth for tenant permissions.
proc ::accounts::sync_access {} {
    variable store
    if {$store eq {}} {error "Accounts are not configured in this worker"}
    set access [dict get [::site::config] account access]
    ::web::user::sync_access $store [dict get $access groups] [dict get $access permissions]
}

# Explicit maintenance uses this tenant's existing encryption and MAC keys.
proc ::accounts::migrate_user_ids {} {
    variable store
    if {$store eq {}} {error "Accounts are not initialized"}
    ::web::user::migrate_user_ids $store
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
