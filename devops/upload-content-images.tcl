#
# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.
#

# Run before ZIP finalization and deployment, using the packaged configuration.
package require Tcl 9.1
set root [file dirname [file dirname [file normalize [info script]]]]
source [file join $root tcl config.tcl]
source [file join $root tcl content-images.tcl]

proc ::content_images::upload_aws {root settings} {
    if {[dict get $settings bucket] eq {}} {error "Production image uploads require content_images.bucket"}
    # Validate both collections and all Markdown references before any upload.
    set stores [snapshots $root [dict replace $settings cloudfront_enabled false] 0]
    set channel [file tempfile staging]
    close $channel
    file delete $staging
    file mkdir $staging
    try {
        # Stage only the validated image inventory, retaining relative paths.
        # Markdown and other files must not be exposed through the CDN.
        foreach {kind collection} {wiki docs blog blog} {
            set directory [file join $staging $collection]
            file mkdir $directory
            dict for {source image} [dict get $stores $kind images] {
                set target [file join $directory $source]
                file mkdir [file dirname $target]
                file copy [dict get $image filename] $target
            }
        }
        foreach collection {docs blog} {
            # Retain old keys for existing pages and rollbacks; never --delete.
            exec aws s3 sync [file join $staging $collection]/ \
                s3://[dict get $settings bucket]/[dict get $settings prefix]/$collection/ \
                --region [dict get $settings region] --no-follow-symlinks --only-show-errors \
                >@stdout 2>@stderr
        }
    } finally {file delete -force $staging}
}

if {[file normalize [info script]] eq [file normalize $::argv0]} {
    if {[llength $argv] != 1} {error "Usage: upload-content-images.tcl PRODUCTION_CONFIG"}
    set ::env(ENV) PROD
    set settings [::app_config::content_images_from_ini [lindex $argv 0] $root]
    ::content_images::upload_aws $root $settings
    puts "Content images synchronized to s3://[dict get $settings bucket]/[dict get $settings prefix]/"
}
