# Run after artifact validation and before deployment. Read only public image
# settings from the exact generated configuration packaged into the Lambda ZIP.
package require Tcl 9.1
if {[llength $argv] != 1} {error "Usage: upload-content-images.tcl PRODUCTION_CONFIG"}
set root [file dirname [file dirname [file normalize [info script]]]]
set ::env(ENV) PROD
source [file join $root tcl config.tcl]
source [file join $root tcl content-images.tcl]
set settings [::app_config::content_images_from_ini [lindex $argv 0] $root]
::content_images::upload $root $settings
puts "Content images synchronized to s3://[dict get $settings bucket]/[dict get $settings prefix]/"
