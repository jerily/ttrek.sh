#
# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.
#

# Check the actual production ZIP, without decrypting config or connecting to AWS.
package require Tcl 9.1
set root [file dirname [file dirname [file normalize [info script]]]]
if {[llength $argv] != 1} {error "Usage: lambda-package.tcl ARCHIVE"}
set archive [file normalize [lindex $argv 0]]
set ::env(ENV) PROD
package require web-static-wiki 1.0.0

# Provide the read bytes test fixture.
proc read_bytes {path} {
    set channel [open $path rb]
    try {read $channel} finally {close $channel}
}

set mount [zipfs mount $archive /ttrek-lambda-package-test]
try {
    # Local dependencies must never enter the production ZIP.
    foreach library {lib lib64} {
        foreach pattern {sqlite* libsqlite* tdbcsqlite* tsession-sqlite* mock-*-app*} {
            if {[llength [glob -nocomplain -directory [file join $mount local $library] $pattern]]} {
                error "Local dependency in production ZIP: $library/$pattern"
            }
        }
    }
    foreach library {lib lib64} {
        if {[llength [glob -nocomplain -types f -directory [file join $mount local $library] \
                tcl8/*/tdbc/sqlite3-* tcl9/*/tdbc/sqlite3-*]]} {
            error "SQLite Tcl module in production ZIP"
        }
    }
    foreach executable {mock-lambda-app mock-proxy-app mock-s3-app mock-ses-app sqlite3} {
        if {[file exists [file join $mount local bin $executable]]} {
            error "Local executable in production ZIP: $executable"
        }
    }
    source [file join $mount tcl config.tcl]
    set releases [::app_config::releases_from_ini [file join $mount etc config.ini] $mount]
    set images [::app_config::content_images_from_ini [file join $mount etc config.ini] $mount]
    if {[dict get $images bucket] eq {}} {error "Packaged content_images.bucket must not be empty"}
    set buildConfig [file join $root devops config.prod.ini]
    if {[info exists ::env(TTREK_PRODUCTION_CONFIG)] && $::env(TTREK_PRODUCTION_CONFIG) ne {}} {
        set buildConfig $::env(TTREK_PRODUCTION_CONFIG)
    }
    set buildImages [::app_config::content_images_from_ini $buildConfig $root]
    foreach key {bucket region prefix url_expiry_seconds endpoint cloudfront_enabled assets_prefix} {
        if {[dict get $images $key] ne [dict get $buildImages $key]} {
            error "Packaged content_images.$key differs from the upload configuration"
        }
    }
    foreach excluded {content etc/content-snapshot.data registry etc/registry-revision} {
        if {[file exists [file join $mount $excluded]]} {error "Unexpected $excluded in production ZIP"}
    }
    set assetManifest [read_bytes [file join $mount public asset-manifest.json]]
    if {[read_bytes [file join $mount etc homepage.json]] ne [read_bytes [file join $root etc homepage.json]]} {
        error "Packaged homepage configuration differs from the checkout"
    }
    if {$assetManifest ne [read_bytes [file join $root public asset-manifest.json]]} {
        error "Packaged browser asset manifest differs from the upload sources"
    }
    set assetPaths [dict values [::tjson::json_to_simple [encoding convertfrom utf-8 $assetManifest]]]
    foreach path [concat $assetPaths {/favicon.ico /assets/favicon.svg}] {
        set relative [string trimleft $path /]
        if {[read_bytes [file join $mount public $relative]] ne [read_bytes [file join $root public $relative]]} {
            error "Packaged browser asset differs from the file to upload: $path"
        }
    }
    set manifest [file join $mount etc releases.json]
    if {[dict get $releases checksums_file] ne $manifest} {
        error "Packaged release settings must use the bundled etc/releases.json"
    }
    set expected [file join $root etc releases.json]
    if {[read_bytes $manifest] ne [read_bytes $expected]} {
        error "Packaged release manifest differs from the checkout"
    }
    set checksums [::app_config::release_checksums $expected [dict get $releases version]]
    if {[dict get $releases checksums] ne $checksums} {
        error "Packaged release settings did not load the production checksums"
    }
    foreach forbidden {etc/config.local.ini etc/config.enc} {
        if {[file exists [file join $mount $forbidden]]} {error "Unexpected host configuration in ZIP: $forbidden"}
    }
    puts "PASS packaged release configuration and manifest ([dict size $checksums] production targets), website content exclusion"
} finally {
    zipfs unmount $mount
}
