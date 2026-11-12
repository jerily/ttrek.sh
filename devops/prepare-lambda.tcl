package require Tcl 9.1
source [file join [file dirname [file dirname [info script]]] runtime paths.tcl]
set siteRoot $::tdevops::runtime::root
foreach asset {public/asset-manifest.json public/css/site.css public/js/site.js public/js/chart.umd.js} {
    if {![file isfile [file join $siteRoot $asset]]} {
        error "Missing browser asset $asset; run ttrek run -script build-assets before packaging"
    }
}
package require http
source [file join $siteRoot tcl site.tcl]
source [file join $siteRoot tcl config.tcl]
set releases [::app_config::releases {}]
if {[info exists ::env(TTREK_PRODUCTION_CONFIG)] && $::env(TTREK_PRODUCTION_CONFIG) ne {}} {
    ::app_config::validate_lambda_config $::env(TTREK_PRODUCTION_CONFIG)
    file copy -force $::env(TTREK_PRODUCTION_CONFIG) [file join $siteRoot etc config.ini]
    # Validate the staged public settings without decrypting secrets or calling AWS.
    set releases [::app_config::releases_from_ini [file join $siteRoot etc config.ini] $siteRoot]
    set images [::app_config::content_images_from_ini [file join $siteRoot etc config.ini] $siteRoot]
    if {[dict get $images bucket] eq {}} {error "Production configuration requires content_images.bucket"}
}
file mkdir [file join $siteRoot data]
::site::configure [dict create rootdir $siteRoot registry_dir [file join $siteRoot registry] \
    releases $releases]
set router [::tpathexp::router]
set savedEnv [array get ::env ENV]
try {
    # Provision only a disposable in-memory fixture for packaging smoke checks.
    # Runtime startup never initializes or imports a database in either mode.
    set ::env(ENV) LOCAL
    # Catalog pages now read the database; validate them against a disposable
    # import of the staged recipes without contacting the production database.
    source [file join $siteRoot tcl telemetry.tcl]
    ::telemetry::init_local {dialect sqlite database :memory:} [list [file join $siteRoot registry]]
    dict set ::site::settings content_connection $::telemetry::connection
    foreach {kind directory} {wiki docs blog blog} {
        ::web::static::${kind}::initdb $::telemetry::connection
        set store [dict get [::content_images::database_stores $::telemetry::connection {}] $kind]
        ::web::static::${kind}::sync $store [file join $siteRoot content $directory]
    }
    ::site::mount $router
    foreach path {/ /docs /docs/getting-started /blog /packages} {
        set response [::site::dispatch $router [dict create method GET path $path]]
        if {[dict get $response statusCode] != 200} {error "staged request failed: $path"}
    }
} finally {
    if {[llength [info commands ::telemetry::close]]} {::telemetry::close}
    $router destroy
    unset ::env(ENV)
    array set ::env $savedEnv
}
