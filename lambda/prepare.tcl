package require Tcl 9.1
source [file join [file dirname [info script]] paths.tcl]
file copy -force [info library] [file join $siteRoot local lib tcl-runtime]
package require http
source [file join $siteRoot tcl site.tcl]
source [file join $siteRoot tcl config.tcl]
source [file join $siteRoot tcl telemetry.tcl]
source [file join $siteRoot tcl search-build.tcl]
::recipe_search::build [file join $siteRoot registry] [file join $siteRoot search-index.json]
file mkdir [file join $siteRoot data]
::site::configure [dict create rootdir $siteRoot registry_dir [file join $siteRoot registry] \
    releases [::app_config::releases {}]]
set router [::tpathexp::router]
try {
    ::site::mount $router
    foreach path {/ /docs /docs/getting-started /blog /packages} {
        set response [::site::dispatch $router [dict create method GET path $path]]
        if {[dict get $response statusCode] != 200} {error "staged request failed: $path"}
    }
} finally {$router destroy}
::telemetry::init -file [file join $siteRoot data telemetry.sqlite3]
::db close
