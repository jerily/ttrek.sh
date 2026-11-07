# Application policy for the shared tdevops Lambda runtime.
namespace eval ::site_lambda {}

proc ::site_lambda::initialize {root} {
    variable router
    source [file join $root tcl site.tcl]
    source [file join $root tcl config.tcl]
    source [file join $root tcl telemetry.tcl]
    if {[::app_config::mode] eq "LOCAL"} {
        source [file join $root tcl local-ratelimit.tcl]
    }
    set config [::app_config::lambda_config $root]
    set dataDirectory /tmp
    if {[info exists ::env(TTREK_LOCAL_RUNTIME_DATA)]} {
        set dataDirectory $::env(TTREK_LOCAL_RUNTIME_DATA)
    }
    file mkdir $dataDirectory
    set channel [file tempfile telemetry [file join $dataDirectory ttrek-telemetry-XXXXXX.sqlite3]]
    close $channel
    file copy -force [file join $root data telemetry.sqlite3] $telemetry
    set settings [dict merge [dict create rootdir $root registry_dir [file join $root registry] \
        releases [::app_config::releases {}] \
        request_monitor [::app_config::request_monitor $config]] [::app_config::lambda_middleware $config]]
    if {[info exists ::env(TTREK_LOCAL_S3_ENDPOINT)]} {
        set ::env(ENV) LOCAL
        source [file join $root tcl local-assets.tcl]
        set release {}
        if {[info exists ::env(TTREK_LOCAL_RELEASES)]} {set release $::env(TTREK_LOCAL_RELEASES)}
        dict set release bucket ttrek-local
        dict set release region us-east-1
        dict set release endpoint $::env(TTREK_LOCAL_S3_ENDPOINT)
        dict set settings releases [::app_config::releases [dict create releases $release]]
        dict set settings assets_endpoint $::env(TTREK_LOCAL_S3_ENDPOINT)
    }
    ::telemetry::init -file $telemetry
    ::site::init_worker $settings
    set router $::site::router
}

proc ::site_lambda::handle {payload context} {
    variable router
    set event [::tjson::json_to_simple [encoding convertfrom utf-8 $payload]]
    if {[dict exists $event version] && [dict get $event version] eq "2.0"} {
        dict set event method [dict get $event requestContext http method]
        dict set event path [dict get $event rawPath]
    } elseif {[dict exists $event httpMethod] && [dict exists $event path]} {
        dict set event method [dict get $event httpMethod]
    } else {error "expected a Function URL or API Gateway HTTP event (payload 1.0 or 2.0)"}
    set headers {}
    if {[dict exists $event headers] && [dict get $event headers] ne "null"} {
        dict for {key value} [dict get $event headers] {dict set headers [string tolower $key] $value}
    }
    if {[dict exists $event cookies]} {dict set headers cookie [join [dict get $event cookies] {; }]}
    dict set event headers $headers
    foreach key {queryStringParameters multiValueQueryStringParameters} {
        if {[dict exists $event $key] && [dict get $event $key] eq "null"} {
            dict unset event $key
        }
    }
    if {[dict exists $event rawQueryString]} {
        dict set event queryString [dict get $event rawQueryString]
    } else {
        # Payload 1.0 provides decoded maps. Reconstruct raw query text for the
        # shared middleware and retain duplicate values for request validation.
        set parameters {}
        if {[dict exists $event queryStringParameters]} {
            dict for {key value} [dict get $event queryStringParameters] {
                dict set parameters $key [list $value]
            }
        }
        if {[dict exists $event multiValueQueryStringParameters]} {
            set parameters [dict merge $parameters [dict get $event multiValueQueryStringParameters]]
        }
        set pairs {}
        dict for {key values} $parameters {
            foreach value $values {lappend pairs $key $value}
        }
        dict set event queryString [::http::formatQuery {*}$pairs]
    }
    if {[dict exists $event body] && [dict exists $event isBase64Encoded] && [dict get $event isBase64Encoded]} {
        dict set event body [binary decode base64 -strict [dict get $event body]]
        dict set event isBase64Encoded false
    }
    if {[dict exists $event requestContext http sourceIp]} {
        dict set context addr [dict get $event requestContext http sourceIp]
    } elseif {[dict exists $event requestContext identity sourceIp]} {
        dict set context addr [dict get $event requestContext identity sourceIp]
    }
    set response [::site::dispatch $router $event $context]
    set headers {}
    dict for {key value} [dict get $response headers] {dict set headers $key [list S $value]}
    set body [dict get $response body]
    set base64 0
    if {[dict exists $response isBase64Encoded]} {set base64 [dict get $response isBase64Encoded]}
    # Carry response bytes safely through JSON and the local Runtime API's HTTP
    # parser, including JavaScript containing unmatched braces and backslashes.
    if {!$base64} {set body [binary encode base64 -maxlen 0 [encoding convertto utf-8 $body]]}
    return [::tjson::typed_to_json [list M [dict create \
        statusCode [list N [dict get $response statusCode]] headers [list M $headers] \
        body [list S $body] isBase64Encoded {BOOL 1}]]]
}
