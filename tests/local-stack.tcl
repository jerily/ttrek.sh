# Exercise the packaged site through all three installed mock applications.
set root [file dirname [file dirname [file normalize [info script]]]]
source [file join $root tests support.tcl]
interp alias {} assert {} ::test_support::assert
interp alias {} read_file {} ::test_support::read_file
interp alias {} write_file {} ::test_support::write_file
interp alias {} sha256 {} ::test_support::sha256
interp alias {} json {} ::test_support::json
lassign [::test_support::ports 3] port lambdaPort s3Port
set base http://127.0.0.1:$port
set s3 http://127.0.0.1:$s3Port
proc request {path args} {
    if {![string match http:* $path]} {set path $::base$path}
    ::test_support::request $path {*}$args
}
proc invoke {event {status 200}} {
    set response [request http://127.0.0.1:$::lambdaPort/2015-03-31/functions/prod-Api-TtrekWebsite-Function/invocations \
        200 POST [encoding convertto utf-8 [::tjson::typed_to_json [list M $event]]] application/json]
    assert {![dict exists $response headers x-amz-function-error]} [dict get $response body]
    set result [json $response]
    assert {[dict get $result statusCode] == $status} $result
    binary decode base64 [dict get $result body]
}
set archive [file join $root dist ttrek-sh.zip]
set before [sha256 [read_file $archive]]
set temporary [::test_support::temporary [file join $root build] {local stack-}]
set state [file join $temporary state]
set seed [file join $temporary s3]
set process {}
try {
    file copy [file join $root dist s3] $seed
    set extraTarget macos-universal2
    set extraBinary [binary format a*c* {uploaded release bytes} {0 255}]
    set extraChecksum [sha256 $extraBinary]
    write_file [file join $seed ttrek-local ttrek 1.0.0 $extraTarget ttrek] {old seed bytes}
    set manifest [file join $temporary releases.json]
    set data {}
    foreach {mode checksum} [list local $extraChecksum prod [string repeat a 64]] {
        dict set data $mode [list M [dict create 1.0.0 [list M [dict create $extraTarget [list S $checksum]]]]]
    }
    write_file $manifest [::tjson::typed_to_json [list M $data]]
    set config [file join $temporary config.ini]
    write_file $config "\[releases\]\nversion=1.0.0\nchecksums_file=$manifest\n"
    set log [file join $temporary services.log]
    set process [::test_support::start [list [file join $root bin start-local.sh] --zip $archive \
        --port $port --lambda-port $lambdaPort --s3-port $s3Port --state-dir $state \
        --s3-dir $seed --lambda-workers 2] $log [dict create TTREK_LOCAL_CONFIG $config] $root]
    set deadline [expr {[clock milliseconds] + 180000}]
    while {1} {
        assert {[::test_support::running $process]} {local stack exited before becoming ready}
        if {![catch {request $s3/; set homepage [dict get [request /] body]}]} {break}
        if {[clock milliseconds] >= $deadline} {error "local stack startup timed out"}
        ::test_support::pause 200
    }
    assert {[string first {href="/docs"} $homepage] >= 0}
    assert {[string first {href="/blog"} $homepage] >= 0}
    assert {[string first {Sign Up} $homepage] < 0}
    set year "&#169; [clock format [clock seconds] -format %Y] JERILY LTD"
    assert {[string first $year $homepage] >= 0}
    foreach path {/docs /docs/getting-started /blog} {
        assert {[::test_support::contains [request $path] $year]} $path
    }
    if {[info exists ::env(TTREK_BROWSER_TESTS)] && $::env(TTREK_BROWSER_TESTS) eq "1"} {
        set python [expr {[info exists ::env(PLAYWRIGHT_PYTHON)] ? $::env(PLAYWRIGHT_PYTHON) : "python3"}]
        exec $python [file join $root tests search_ui.py] $base >@stdout 2>@stderr
    }
    foreach {path expected} {
        /docs {Getting started} /blog {No published content yet.}
        /docs/getting-started {ttrek init -y} /docs/registries private-ttrek-registry
        /docs/_assets/style.css .cards /packages tjson /search?q=web twebserver
        /registry/autocomplete?q=web twebserver /package/tcl 9.1.0
        /package/web-static-blog 0.1.0 /registry/web-static-wiki 0.1.0
        /registry/tcl 9.1.0 /registry/search?q=web twebserver
        /request-monitor data-chart-config /init TTREK_UPDATE_ROOT
    } {
        assert {[::test_support::contains [request $path] $expected]} "unexpected response for $path"
        puts "PASS GET $path"
    }
    set docs [request /docs/getting-started]
    assert {[::test_support::contains $docs {<title>Getting started}]}
    assert {![::test_support::contains $docs {new ClipboardJS}]}
    assert {[string first {script-src 'self'} [dict get $docs headers content-security-policy]] >= 0}
    assert {[dict get [request /docs 200 HEAD] body] eq {}}
    foreach path {/docs/missing /docs/_edit/getting-started /docs/_new /blog/_new /blog/_edit/post} {request $path 404}
    request /docs 405 POST
    request /registry/search?q=one&q=two 400
    request /registry/autocomplete?q=one&q=two 400
    request /telemetry/collect/demo/1.0.0 400 POST invalid
    puts {PASS static content, HEAD, read-only routes and request validation}

    set event [dict create httpMethod {S GET} path {S /registry/search} headers {N null} \
        queryStringParameters {M {q {S web}}} multiValueQueryStringParameters {N null}]
    set names [lmap match [::tjson::json_to_simple [invoke $event]] {dict get $match name}]
    foreach name {web-static-blog web-static-wiki} {
        assert {[lsearch -exact $names $name] >= 0 && [lsearch -exact $names $name] < [lsearch -exact $names twebserver]}
    }
    dict set event multiValueQueryStringParameters {M {q {L {{S web} {S server}}}}}
    invoke $event 400
    set telemetry [::tjson::typed_to_json {M {action {S install} outcome {S success} is_toplevel {BOOL 1} os {S Linux} arch {S x86_64}}}]
    set event [dict create httpMethod {S POST} path {S /telemetry/collect/demo/1.0.0} \
        headers {M {Content-Type {S application/json}}} body [list S [binary encode base64 -maxlen 0 $telemetry]] \
        isBase64Encoded {BOOL 1}]
    assert {[invoke $event] eq "ok"}
    puts {PASS payload 1.0 queries, duplicate validation and base64 request body}

    set original [read_file [file join $root public css docs.css]]
    assert {[dict get [request /css/docs.css] body] eq $original}
    set changed "$original\n/* served from mock S3 */\n"
    request $s3/ttrek-assets/css/docs.css 200 PUT $changed text/css
    assert {[dict get [request /css/docs.css] body] eq $changed}
    set bytes {}
    for {set i 0} {$i < 256} {incr i} {lappend bytes $i}
    set binary [binary format c* [concat $bytes $bytes $bytes $bytes $bytes]]
    request $s3/ttrek-local/binary.bin 200 PUT $binary
    assert {[dict get [request $s3/ttrek-local/binary.bin] body] eq $binary}
    puts {PASS S3-backed website assets and binary object storage}

    set release [lindex [glob -directory [file join $root dist s3 ttrek-local ttrek 1.0.0] */ttrek] 0]
    set target [file tail [file dirname $release]]
    set download [dict get [request /dist/$target/ttrek] body]
    assert {[sha256 $download] eq [sha256 [read_file $release]]}
    set metadata [json [request /releases/latest/$target]]
    assert {[dict get $metadata sha256] eq [sha256 $download]}
    assert {[string first $s3/ttrek-local/ [dict get $metadata url]] == 0}
    puts {PASS signed release redirect, exact executable bytes and checksum metadata}
    request $s3/ttrek-local/ttrek/1.0.0/$extraTarget/ttrek 200 PUT $extraBinary
    set download [dict get [request /dist/$extraTarget/ttrek] body]
    set metadata [json [request /releases/latest/$extraTarget]]
    assert {$download eq $extraBinary && [dict get $metadata sha256] eq $extraChecksum}
    assert {[dict get $metadata version] eq "1.0.0"}
    puts {PASS configured local checksum manifest takes precedence over seed and production hashes}

    ::test_support::stop $process
    assert {![llength [glob -nocomplain -directory $state *]]} {temporary service directories were not cleaned}
    assert {[sha256 [read_file $archive]] eq $before} {archive changed during the test}
    foreach selected [list $port $lambdaPort $s3Port] {assert {![::test_support::port_open $selected]} {service left running}}
    puts {PASS clean shutdown and unchanged archive}
} on error {message options} {
    if {[info exists log] && [file exists $log]} {puts stderr [read_file $log]}
    return -options $options $message
} finally {
    try {::test_support::stop $process} finally {file delete -force $temporary}
}
