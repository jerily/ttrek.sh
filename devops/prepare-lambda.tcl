# 
# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.
# 

package require Tcl 9.1
source [file join [file dirname [file dirname [info script]]] runtime paths.tcl]
set siteRoot $::tdevops::runtime::root
source [file join $siteRoot devops stage-registry.tcl]
set registrySource {}
if {[info exists ::env(TTREK_PUBLIC_REGISTRY)]} {
    set registrySource $::env(TTREK_PUBLIC_REGISTRY)
}
::registry_build::stage $siteRoot $registrySource
foreach asset {public/asset-manifest.json public/css/site.css public/js/site.js public/js/chart.umd.js} {
    if {![file isfile [file join $siteRoot $asset]]} {
        error "Missing browser asset $asset; run ttrek run -script build-assets before packaging"
    }
}
package require http
package require web-user 0.7.2
package require web-forum 0.3.4
package require pure-tcl-aws-ses 1.0.0
package require pure-tcl-aws-sqs 1.0.0
package require pure-tcl-aws-lambda 1.0.0
source [file join $siteRoot tcl site.tcl]
source [file join $siteRoot tcl config.tcl]
set releases [::app_config::releases {}]
set monitor [::app_config::request_monitor {}]
set production [expr {[info exists ::env(TTREK_PRODUCTION_CONFIG)] && $::env(TTREK_PRODUCTION_CONFIG) ne {}}]
if {$production} {
    ::app_config::validate_lambda_config $::env(TTREK_PRODUCTION_CONFIG)
    file copy -force $::env(TTREK_PRODUCTION_CONFIG) [file join $siteRoot etc config.ini]
    # Validate the staged public settings without decrypting secrets or calling AWS.
    set releases [::app_config::releases_from_ini [file join $siteRoot etc config.ini] $siteRoot]
    set images [::app_config::content_images_from_ini [file join $siteRoot etc config.ini] $siteRoot]
    set monitor [::app_config::request_monitor [::tconfig::read_config [file join $siteRoot etc config.ini]]]
    if {[dict get $images bucket] eq {}} {error "Production configuration requires content_images.bucket"}
    if {[info exists ::env(CONTENT_IMAGES_BUCKET)] && $::env(CONTENT_IMAGES_BUCKET) ne [dict get $images bucket]} {
        error "Upload bucket differs from the production content_images.bucket"
    }
    ::content_images::snapshots $siteRoot [dict replace $images cloudfront_enabled false] 0
}
file mkdir [file join $siteRoot data]
::site::configure [dict create rootdir $siteRoot releases $releases]
# This is independent of database fixtures and must run in PostgreSQL-only builds.
::views::validate_all [dict get $monitor master_template]
# Production installations omit SQLite; use only dependencies already present.
if {[catch {package require tdbc::sqlite3} message options]} {
    if {[dict get $options -errorcode] ne {TCL PACKAGE UNFOUND} ||
            [llength [package versions tdbc::sqlite3]]} {
        return -options $options $message
    }
    puts "Skipping SQLite-backed packaging smoke checks: tdbc::sqlite3 is not installed."
    if {$production} {file delete -force [file join $siteRoot content]}
    return
}
set router [::tpathexp::router]
set savedEnv [array get ::env ENV]
set accountProbe [file tempfile accountProbeDirectory]
close $accountProbe
file delete $accountProbeDirectory
file mkdir $accountProbeDirectory
try {
    # Provision only a disposable in-memory fixture for packaging smoke checks.
    # Runtime startup never initializes or imports a database in either mode.
    set ::env(ENV) LOCAL
    # Validate every staged recipe in a disposable catalog without contacting
    # the production database. The deployed database changes only on manual sync.
    source [file join $siteRoot tcl telemetry.tcl]
    ::telemetry::init_local {dialect sqlite database :memory:} [list [file join $siteRoot registry]]
    dict set ::site::settings content_connection $::telemetry::connection
    foreach {kind directory} {wiki docs blog blog} {
        ::web::static::${kind}::initdb $::telemetry::connection
        set store [dict get [::content_images::database_stores $::telemetry::connection {}] $kind]
        ::web::static::${kind}::sync $store [file join $siteRoot content $directory]
    }
    ::web::user::initdb $::telemetry::connection
    ::web::forum::initdb $::telemetry::connection
    dict set ::site::settings account [::app_config::account {} $siteRoot $accountProbeDirectory]
    set separated [::private_config::partition $::site::settings]
    set ::site::settings [dict get $separated config]
    ::site::mount $router -secret_config [dict get $separated secret_config]
    foreach path {/ /docs /docs/getting-started /blog /packages /forum /user/register /user/login /user/forgot} {
        set response [::site::dispatch $router [dict create method GET path $path]]
        if {[dict get $response statusCode] != 200} {error "staged request failed: $path"}
    }
} finally {
    file delete -force $accountProbeDirectory
    if {[llength [info commands ::telemetry::close]]} {::telemetry::close}
    $router destroy
    unset ::env(ENV)
    array set ::env $savedEnv
}
if {$production} {file delete -force [file join $siteRoot content]}
