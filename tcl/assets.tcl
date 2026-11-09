namespace eval ::assets {
    variable manifest {}
}

proc ::assets::read_bytes {path} {
    set channel [open $path rb]
    try {read $channel} finally {close $channel}
}

proc ::assets::digest {bytes} {
    binary encode hex [::twebserver::sha256 $bytes]
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
        set path [file join $root public [string trimleft $versioned /]]
        if {![file isfile $path] || [string range [digest [read_bytes $path]] 0 15] ne $hash} {
            error "Missing or corrupt versioned asset: $versioned; rebuild browser assets"
        }
    }
}

proc ::assets::url {path} {
    variable manifest
    if {![dict exists $manifest $path]} {error "Asset missing from manifest: $path"}
    dict get $manifest $path
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
    set digest [digest $bytes]
    set etag "\"sha256-$digest\""
    set policy no-cache
    if {[string match /assets/versioned/* $path] &&
        [regexp {\.([0-9a-f]{16})\.(css|js)$} $path -> hash ext]} {
        # A stale/corrupt object must never poison an immutable browser cache.
        if {$hash ne [string range $digest 0 15]} {return [unavailable]}
        set policy {public, max-age=31536000, immutable}
    }
    set headers [dict create content-type $type Cache-Control $policy ETag $etag]
    return [dict create statusCode 200 headers $headers isBase64Encoded true \
        body [binary encode base64 -maxlen 0 $bytes]]
}
