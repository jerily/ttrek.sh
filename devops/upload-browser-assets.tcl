#
# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.
#

# Publish only browser assets, after validating the production artifact and
# before deployment. Retain previous fingerprinted files for already-open pages.
package require Tcl 9.1
package require tjson
set browserAssetsRoot [file dirname [file dirname [file normalize [info script]]]]
source [file join $browserAssetsRoot tcl config.tcl]
source [file join $browserAssetsRoot tcl content-images.tcl]
source [file join $browserAssetsRoot tcl assets.tcl]

source [file join $browserAssetsRoot tcl browser-assets.tcl]

if {[file normalize [info script]] eq [file normalize $::argv0]} {
    if {[llength $argv] != 1} {error "Usage: upload-browser-assets.tcl PRODUCTION_CONFIG"}
    set ::env(ENV) PROD
    set settings [::app_config::content_images_from_ini [lindex $argv 0] $browserAssetsRoot]
    set uploaded [::browser_assets::upload $browserAssetsRoot $settings]
    puts "Uploaded $uploaded browser assets"
}
