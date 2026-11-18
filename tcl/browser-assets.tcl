# Browser-asset publication during deployment.
namespace eval ::browser_assets {}

# Collect local files recursively for asset publication.
proc ::browser_assets::files {directory} {
    set files {}
    foreach path [lsort [glob -nocomplain -directory $directory *]] {
        switch -- [file type $path] {
            link {error "Browser assets must not be symbolic links: $path"}
            directory {lappend files {*}[files $path]}
            file {lappend files $path}
        }
    }
    return $files
}

# Build the browser-asset inventory from local files.
proc ::browser_assets::inventory {root} {
    ::assets::load $root
    set public [file join $root public]
    set inventory {}
    foreach {path type} {/favicon.ico image/vnd.microsoft.icon /assets/favicon.svg image/svg+xml} {
        dict set inventory $path [dict create filename [file join $public [string trimleft $path /]] type $type immutable false]
    }
    # Include previous builds restored from S3, as well as the current manifest.
    foreach kind {css js} {
        foreach filename [files [file join $public assets versioned $kind]] {
            set path [string range $filename [string length $public] end]
            if {[regexp {^/assets/versioned/(css|js)/[a-zA-Z0-9_./-]+\.[0-9a-f]{16}\.(css|js)$} $path]} {
                set type [expr {[file extension $filename] eq ".css" ? "text/css" : "application/javascript"}]
                dict set inventory $path [dict create filename $filename type $type immutable true]
            } elseif {[regexp {^/assets/versioned/js/[a-zA-Z0-9_-]+\.LICENSE\.txt$} $path]} {
                dict set inventory $path [dict create filename $filename type text/plain immutable false]
            }
        }
    }
    dict for {original path} $::assets::manifest {
        if {![dict exists $inventory $path]} {error "Missing browser asset: $path"}
    }
    package require treqmon 2.1.0
    dict set inventory /request-monitor/_assets/charts.js [dict create \
        filename [file join $::treqmon::view::asset_dir charts.js] type application/javascript immutable false]
    dict for {original asset} [::assets::package_files] {
        dict set inventory $original $asset
    }
    # Validate all fixed files before any S3 operation as well.
    dict for {path asset} $inventory {
        set filename [dict get $asset filename]
        if {![file isfile $filename] || [file type $filename] eq "link" || ![file readable $filename]} {
            error "Missing or unreadable browser asset: $path"
        }
    }
    return $inventory
}

# Upload the selected artifacts to the configured storage service.
proc ::browser_assets::upload {root settings} {
    if {![dict get $settings cloudfront_enabled]} {return 0}
    if {[dict get $settings bucket] eq {}} {error "Browser asset uploads require content_images.bucket"}
    set inventory [inventory $root]
    # Uploads do not require the runtime distribution URL imported by SAM.
    set options [::content_images::options [dict replace $settings cloudfront_enabled false] wiki 0]
    set client [dict get $options -s3 client]
    set bucket [dict get $settings bucket]
    set prefix [dict get $settings assets_prefix]
    set uploaded 0
    dict for {path asset} $inventory {
        set key $prefix$path
        if {[dict get $asset immutable] && $key in [$client ls $bucket $key]} {continue}
        $client put $bucket $key [dict get $asset filename] [dict get $asset type]
        incr uploaded
    }
    return $uploaded
}
