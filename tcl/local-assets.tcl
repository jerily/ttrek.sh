package require http

# The launcher supplies a trusted loopback S3 origin. Keep browser requests on
# the proxy's origin so documentation's self-only stylesheet policy still holds.
proc ::site::s3_asset {path type} {
    set endpoint [dict get [::site::config] assets_endpoint]
    set segments [lmap segment [split [string trimleft $path /] /] {
        ::twebserver::encode_uri_component $segment
    }]
    set token [::http::geturl $endpoint/ttrek-assets/[join $segments /] \
        -binary 1 -timeout 5000 -keepalive 0]
    try {
        set status [::http::ncode $token]
        if {$status != 200} {
            return [::twebserver::build_response [expr {$status == 404 ? 404 : 502}] text/plain {Asset unavailable}]
        }
        return [dict create statusCode 200 headers [dict create content-type $type] \
            isBase64Encoded true body [binary encode base64 -maxlen 0 [::http::data $token]]]
    } finally {::http::cleanup $token}
}
