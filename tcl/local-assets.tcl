package require http

# The launcher supplies a trusted loopback S3 origin. Keep browser requests on
# the proxy's origin so documentation's self-only stylesheet policy still holds.
proc ::site::s3_asset {path type request} {
    set endpoint [dict get [::site::config] assets_endpoint]
    set segments [lmap segment [split [string trimleft $path /] /] {
        ::twebserver::encode_uri_component $segment
    }]
    set token [::http::geturl $endpoint/ttrek-assets/[join $segments /] \
        -binary 1 -timeout 5000 -keepalive 0]
    try {
        set status [::http::ncode $token]
        if {$status != 200} {
            return [::assets::unavailable [expr {$status == 404 ? 404 : 502}]]
        }
        return [::assets::respond $path $request $type [::http::data $token]]
    } finally {::http::cleanup $token}
}
