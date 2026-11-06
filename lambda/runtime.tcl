package require Tcl 8.6 9
source [file join [file dirname [info script]] paths.tcl]
package require http

namespace eval ::site_lambda {}

proc ::site_lambda::request {path args} {
    set url http://$::env(AWS_LAMBDA_RUNTIME_API)/2018-06-01/runtime/$path
    # Close each completed Runtime API connection so local shutdown does not
    # wait for idle keepalive sockets to expire during the mock server's drain.
    set headers {}
    if {[dict exists $args -headers]} {set headers [dict get $args -headers]}
    dict set args -headers [concat $headers {Connection close}]
    set token [::http::geturl $url -binary 1 -keepalive 0 {*}$args]
    try {
        if {[::http::status $token] ne "ok" || [::http::ncode $token] ni {200 202}} {
            error "Lambda Runtime API request failed: [::http::status $token] [::http::ncode $token]"
        }
        set headers {}
        foreach {key value} [::http::meta $token] {dict set headers [string tolower $key] $value}
        return [list [::http::data $token] $headers]
    } finally {::http::cleanup $token}
}

proc ::site_lambda::post {path json {headers {}}} {
    request $path -method POST -timeout 10000 -type application/json \
        -headers $headers -query [encoding convertto utf-8 $json]
}

proc ::site_lambda::report_error {path message {headers {}}} {
    # Work even when loading tjson failed during initialization.
    set escaped {}
    foreach character [split $message {}] {
        scan $character %c code
        if {$character in {\" \\} || $code < 32} {
            append escaped [format {\u%04x} $code]
        } else {append escaped $character}
    }
    set json [format {"errorMessage":"%s","errorType":"TtrekSiteError"} $escaped]
    post $path \{$json\} [concat $headers {Lambda-Runtime-Function-Error-Type Runtime.TtrekSiteError}]
}

proc ::site_lambda::initialize {} {
    variable router
    source [file join $::siteRoot tcl site.tcl]
    source [file join $::siteRoot tcl config.tcl]
    source [file join $::siteRoot tcl telemetry.tcl]
    set dataDirectory /tmp
    if {[info exists ::env(TTREK_LOCAL_RUNTIME_DATA)]} {
        set dataDirectory $::env(TTREK_LOCAL_RUNTIME_DATA)
    }
    file mkdir $dataDirectory
    set channel [file tempfile database [file join $dataDirectory ttrek-docs-XXXXXX.sqlite3]]
    close $channel
    file copy -force [file join $::siteRoot data docs.sqlite3] $database
    set channel [file tempfile telemetry [file join $dataDirectory ttrek-telemetry-XXXXXX.sqlite3]]
    close $channel
    file copy -force [file join $::siteRoot data telemetry.sqlite3] $telemetry
    set settings [dict create rootdir $::siteRoot registry_dir [file join $::siteRoot registry] \
        docs_database $database releases [::app_config::releases {}] \
        treqmon {store {tsvstore {history_max_events 10000}}}]
    if {[info exists ::env(TTREK_LOCAL_S3_ENDPOINT)]} {
        set ::env(ENV) LOCAL
        source [file join $::siteRoot tcl local-assets.tcl]
        set release [dict create bucket ttrek-local region us-east-1 prefix ttrek/1.0.0 \
            endpoint $::env(TTREK_LOCAL_S3_ENDPOINT)]
        if {[info exists ::env(TTREK_LOCAL_RELEASE_TARGET)]} {
            dict set release sha256_$::env(TTREK_LOCAL_RELEASE_TARGET) $::env(TTREK_LOCAL_RELEASE_SHA256)
        }
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

proc ::site_lambda::run {} {
    if {![info exists ::env(AWS_LAMBDA_RUNTIME_API)] || $::env(AWS_LAMBDA_RUNTIME_API) eq {}} {
        error "AWS_LAMBDA_RUNTIME_API is required"
    }
    if {[catch {initialize} message]} {
        report_error init/error $message
        error $message
    }
    while {1} {
        # No timeout: Lambda may freeze this process while /next is waiting.
        lassign [request invocation/next -timeout 0] payload context
        set id [dict get $context lambda-runtime-aws-request-id]
        set headers {}
        if {[dict exists $context lambda-runtime-invocation-id]} {
            lappend headers Lambda-Runtime-Invocation-Id [dict get $context lambda-runtime-invocation-id]
        }
        unset -nocomplain ::env(_X_AMZN_TRACE_ID)
        if {[dict exists $context lambda-runtime-trace-id]} {
            set ::env(_X_AMZN_TRACE_ID) [dict get $context lambda-runtime-trace-id]
        }
        if {[catch {handle $payload $context} response options]} {
            puts stderr [dict get $options -errorinfo]
            report_error invocation/$id/error $response $headers
        } else {post invocation/$id/response $response $headers}
    }
}

if {[catch {::site_lambda::run} message]} {
    puts stderr $message
    exit 1
}
