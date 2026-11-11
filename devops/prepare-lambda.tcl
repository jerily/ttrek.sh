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
    # Check both collections using the packaged image files. Rendering the smoke
    # requests below stays independent of AWS credentials and URL signing.
    ::content_images::snapshots $siteRoot $images 0
}
source [file join $siteRoot tcl search-build.tcl]
::recipe_search::build [file join $siteRoot registry] [file join $siteRoot etc search-index.json]
file mkdir [file join $siteRoot data]
::site::configure [dict create rootdir $siteRoot registry_dir [file join $siteRoot registry] \
    releases $releases]
set router [::tpathexp::router]
try {
    # Smoke requests do not require AWS credentials; image validation ran above.
    ::site::mount $router
    foreach path {/ /docs /docs/getting-started /blog /packages} {
        set response [::site::dispatch $router [dict create method GET path $path]]
        if {[dict get $response statusCode] != 200} {error "staged request failed: $path"}
    }
} finally {$router destroy}
