source [file join [file dirname [info script]] private-config.tcl]
# 
# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.
# 

# Share image-store clients across the content collections.
namespace eval ::content_images {variable clients {}}

# One production toggle and imported origin for images and browser assets.
proc ::content_images::cdn_url {settings} {
    if {$settings eq {} || [::app_config::mode] ne "PROD" || ![dict get $settings cloudfront_enabled]} {return {}}
    if {![info exists ::env(CONTENT_IMAGES_CLOUDFRONT_URL)] ||
            ![regexp {^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?/?$} $::env(CONTENT_IMAGES_CLOUDFRONT_URL)]} {
        error "CloudFront requires the HTTPS CONTENT_IMAGES_CLOUDFRONT_URL imported by SAM"
    }
    return [string trimright $::env(CONTENT_IMAGES_CLOUDFRONT_URL) /]
}

# The host owns one SDK client per settings dictionary in each worker. Both
# packages borrow it; credentials come from the SDK's refreshing provider chain.
proc ::content_images::options {settings kind {uploadMissing {}}} {
    switch -- $kind {
        wiki {set directoryKey docs_directory; set collection docs}
        blog {set directoryKey blog_directory; set collection blog}
        default {error "Unknown content collection: $kind"}
    }
    if {$settings eq {} || [dict get $settings bucket] eq {}} {return {}}
    if {$uploadMissing eq {}} {set uploadMissing [expr {[::app_config::mode] eq "LOCAL"}]}
    set s3 [dict create client [client $settings] bucket [dict get $settings bucket] \
        prefix [dict get $settings prefix]/$collection url_expiry_seconds [dict get $settings url_expiry_seconds] \
        http_endpoint [dict get $settings endpoint] upload_missing $uploadMissing]
    set cdn [cdn_url $settings]
    if {$cdn ne {}} {dict set s3 cdn_url $cdn}
    return [list -images-directory [dict get $settings $directoryKey] -s3 $s3]
}

proc ::content_images::client {settings} {
    variable clients
    package require pure-tcl-aws-s3 1.0.0
    set clientSettings [dict create region [dict get $settings region]]
    set endpoint [dict get $settings endpoint]
    if {$endpoint ne {}} {
        dict set clientSettings endpoint $endpoint
        dict set clientSettings aws_access_key_id local
        dict set clientSettings aws_secret_access_key local
    }
    if {![dict exists $clients $clientSettings]} {
        dict set clients $clientSettings [::aws::s3::create $clientSettings]
    }
    return [dict get $clients $clientSettings]
}

# Build and runtime use the same directories, image options and navigation rules.
proc ::content_images::snapshots {root settings {uploadMissing {}}} {
    package require web-static-wiki 0.1.13
    package require web-static-blog 0.1.12
    set stores {}
    foreach {kind title directory} {wiki Documentation docs blog Blog blog} {
        set imageOptions [options $settings $kind $uploadMissing]
        set contentOptions {}
        if {$kind eq "wiki"} {set contentOptions {-exclude_from_navigation images}}
        dict set stores $kind [::web::static::${kind}::create \
            -directory [file join $root content $directory] -title $title \
            {*}$contentOptions {*}$imageOptions]
    }
    return $stores
}

# Lightweight database handles: no source reads, image hashing, schema changes,
# or content queries until a route requests an item or listing.
proc ::content_images::database_stores {connection settings} {
    set stores {}
    foreach kind {wiki blog} {dict set stores $kind [database_store $kind $connection $settings]}
    return $stores
}

proc ::content_images::database_store {kind connection settings} {
    if {$kind ni {wiki blog}} {error "Unknown content store: $kind"}
    package require web-static-$kind
    set title [dict get {wiki Documentation blog Blog} $kind]
    set contentOptions {}
    if {$kind eq "wiki"} {set contentOptions {-exclude_from_navigation images}}
    ::web::static::${kind}::create -connection $connection -domain ttrek.sh -title $title \
        {*}$contentOptions {*}[options $settings $kind 0]
}

# Open the database connection used by this service.
proc ::content_images::connect {settings args} {
    set settings [::private_config::password $settings {*}$args]
    package require tpersist 0.1.4
    set options {-autobegin false}
    dict for {key value} $settings {lappend options -$key $value}
    if {[catch {::tpersist::db_connect {*}$options} connection]} {
        return -code error -errorcode {CONTENT CONNECT} "Could not connect to the content database"
    }
    return $connection
}

# Mount the latest archive for this invocation. Database rows retain portable
# source paths after the temporary archive has been released.
proc ::content_images::archive_items {root settings} {
    if {[dict get $settings bucket] eq {}} {error "Production image uploads require content_images.bucket"}
    set channel [file tempfile archive]
    close $channel
    try {
        [client $settings] get [dict get $settings bucket] ttrek/content/latest.zip $archive
        set mount [zipfs mount $archive /[file tail $archive]]
        try {
            foreach key {docs_directory blog_directory} {
                set path [dict get $settings $key]
                if {[string first "$root/content/" "$path/"] != 0} {
                    error "Production content_images.$key must be under content/"
                }
                dict set settings $key [file join $mount [string range $path [string length "$root/"] end]]
            }
            set stores [snapshots $mount [dict replace $settings cloudfront_enabled false] 0]
            set collections {}
            dict for {kind store} $stores {
                ::web::static::${kind}::sync_images $store
                set items [dict get $store items]
                dict for {path item} $items {
                    set source [dict get $item source_path]
                    if {[string first "$mount/" $source] == 0} {
                        dict set items $path source_path [string range $source [string length "$mount/"] end]
                    }
                }
                dict set collections $kind $items
            }
            return $collections
        } finally {zipfs unmount $mount}
    } finally {file delete -force $archive}
}
