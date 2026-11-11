namespace eval ::content_images {variable clients {}}

# The host owns one SDK client per settings dictionary in each worker. Both
# packages borrow it; credentials come from the SDK's refreshing provider chain.
proc ::content_images::options {settings {uploadMissing {}}} {
    variable clients
    if {$settings eq {} || [dict get $settings bucket] eq {}} {return {}}
    if {$uploadMissing eq {}} {set uploadMissing [expr {[::app_config::mode] eq "LOCAL"}]}
    package require awss3 1.0.17
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
    set s3 [dict create client [dict get $clients $clientSettings] bucket [dict get $settings bucket] \
        prefix [dict get $settings prefix] url_expiry_seconds [dict get $settings url_expiry_seconds] \
        http_endpoint $endpoint upload_missing $uploadMissing]
    return [list -images-directory [dict get $settings directory] -s3 $s3]
}

# Build and runtime use the same directories, image options and navigation rules.
proc ::content_images::snapshots {root settings {uploadMissing {}}} {
    package require web-static-wiki 0.1.3
    package require web-static-blog 0.1.2
    set imageOptions [options $settings $uploadMissing]
    set stores {}
    foreach {kind title directory} {wiki Documentation docs blog Blog blog} {
        set contentOptions {}
        if {$kind eq "wiki"} {set contentOptions {-exclude_from_navigation images}}
        dict set stores $kind [::web::static::${kind}::create \
            -directory [file join $root content $directory] -title $title \
            {*}$contentOptions {*}$imageOptions]
    }
    return $stores
}

proc ::content_images::upload {root settings} {
    if {[dict get $settings bucket] eq {}} {error "Production image uploads require content_images.bucket"}
    # Validate both collections before the first upload. The second pass uses the
    # packages' normal content hashes, MIME types and missing-object checks.
    snapshots $root $settings 0
    snapshots $root $settings 1
    return
}
