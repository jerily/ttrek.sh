namespace eval ::assets {
    variable manifest {}
    variable cdn_origin {}
    variable cdn_prefix {}
}

proc ::assets::configure {settings} {
    variable cdn_origin [::content_images::cdn_url $settings]
    variable cdn_prefix {}
    if {$cdn_origin ne {}} {set cdn_prefix [dict get $settings assets_prefix]}
}

proc ::assets::read_bytes {path} {
    set channel [open $path rb]
    try {read $channel} finally {close $channel}
}

proc ::assets::load {root} {
    variable manifest
    set filename [file join $root public asset-manifest.json]
    if {![file isfile $filename]} {
        error "Missing asset manifest; run ttrek run -script build-assets before starting or packaging"
    }
    set manifest [::tjson::json_to_simple [encoding convertfrom utf-8 [read_bytes $filename]]]
    dict for {original versioned} $manifest {
        if {![regexp {^/(css|js)/[a-zA-Z0-9_./-]+\.(css|js)$} $original] ||
            [string first .. $original] >= 0 ||
            ![regexp {^/assets/versioned/(css|js)/[a-zA-Z0-9_./-]+\.([0-9a-f]{16})\.(css|js)$} $versioned -> kind hash ext] ||
            $versioned ne "/assets/versioned[file rootname $original].$hash[file extension $original]"} {
            error "Invalid asset manifest entry: $original"
        }
    }
}

proc ::assets::url {path} {
    variable manifest
    variable cdn_origin
    variable cdn_prefix
    if {[dict exists $manifest $path]} {
        set path [dict get $manifest $path]
    } elseif {$path ni {/favicon.ico /assets/favicon.svg /request-monitor/_assets/charts.js}} {
        error "Asset missing from manifest: $path"
    }
    if {$cdn_origin ne {}} {return $cdn_origin/$cdn_prefix$path}
    return $path
}

# Package layouts carry their own CSP. Add only the configured CDN origin to
# the directives needed by external scripts, stylesheets and favicon images.
proc ::assets::allow_cdn {response} {
    variable cdn_origin
    if {$cdn_origin eq {}} {return $response}
    set policy [::responses::header $response Content-Security-Policy]
    if {$policy eq {}} {return $response}
    set directives {}
    foreach directive [split $policy {;}] {
        set directive [string trim $directive]
        if {$directive eq {}} {continue}
        if {[lindex $directive 0] in {script-src style-src img-src} && $cdn_origin ni $directive} {
            append directive " $cdn_origin"
        }
        lappend directives $directive
    }
    ::responses::set_header response Content-Security-Policy [join $directives {; }]
    return $response
}

# GET/HEAD use weak comparison, including a list of validators and '*'. Parse
# complete entity tags so a comma inside an opaque tag cannot become a match.
proc ::assets::matches {value etag} {
    set value [string trim $value " \t"]
    if {$value eq "*"} {return 1}
    set matched 0
    while {$value ne {}} {
        if {[string index $value 0] eq ","} {
            set value [string trimleft [string range $value 1 end] " \t"]
            continue
        }
        if {![regexp {^(?:W/)?("[\x21\x23-\x7e\x80-\xff]*")[ \t]*(.*)$} $value -> tag rest]} {return 0}
        if {$tag eq $etag} {set matched 1}
        if {$rest ne {} && [string index $rest 0] ne ","} {return 0}
        set value $rest
    }
    return $matched
}

proc ::assets::unavailable {{status 404}} {
    set response [::twebserver::build_response $status text/plain {Asset unavailable}]
    dict set response headers Cache-Control no-store
    return $response
}

proc ::assets::respond {path request type bytes} {
    variable manifest
    set versioned $path
    if {[dict exists $manifest $path]} {set versioned [dict get $manifest $path]}
    set etag {}
    # Trust build-time fingerprints, including retained URLs from older builds.
    if {[string match /assets/versioned/* $versioned] &&
        [regexp {\.([0-9a-f]{16})\.(css|js)$} $versioned -> hash]} {
        set etag "\"sha256-$hash\""
    }
    set policy no-cache
    if {[string match /assets/versioned/* $path] && $etag ne {}} {
        set policy {public, max-age=31536000, immutable}
    } elseif {$path in {/assets/favicon.svg /favicon.ico}} {
        # Three months (90 days).
        set policy {public, max-age=7776000}
    }
    set headers [dict create content-type $type Cache-Control $policy]
    if {$etag ne {}} {dict set headers ETag $etag}
    return [dict create statusCode 200 headers $headers isBase64Encoded true \
        body [binary encode base64 -maxlen 0 $bytes]]
}
