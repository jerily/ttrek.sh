# Exercise the packaged site through all three installed mock applications.
set root [file dirname [file dirname [file normalize [info script]]]]
source [file join $root tests support.tcl]
interp alias {} assert {} ::test_support::assert
interp alias {} read_file {} ::test_support::read_file
interp alias {} write_file {} ::test_support::write_file
interp alias {} sha256 {} ::test_support::sha256
interp alias {} json {} ::test_support::json
lassign [::test_support::ports 4] port lambdaPort s3Port cachePort
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
if {[info exists ::env(TTREK_TEST_SITE_ZIP)]} {set archive $::env(TTREK_TEST_SITE_ZIP)}
set seedSource [file join $root dist s3]
if {[info exists ::env(TTREK_TEST_S3_SEED)]} {set seedSource $::env(TTREK_TEST_S3_SEED)}
set before [sha256 [read_file $archive]]
set temporary [::test_support::temporary [file join $root build] {local stack-}]
set state [file join $temporary state]
set seed [file join $temporary s3]
set process {}
set cacheProcess {}
try {
    file copy $seedSource $seed
    set extraTarget macos-universal2
    set extraBinary [binary format a*c* {uploaded release bytes} {0 255}]
    set extraChecksum [sha256 $extraBinary]
    write_file [file join $seed ttrek-local ttrek 1.3.0 $extraTarget ttrek] {old seed bytes}
    set manifest [file join $temporary releases.json]
    set data {}
    foreach {mode checksum} [list local $extraChecksum prod [string repeat a 64]] {
        dict set data $mode [list M [dict create 1.3.0 [list M [dict create $extraTarget [list S $checksum]]]]]
    }
    write_file $manifest [::tjson::typed_to_json [list M $data]]
    set config [file join $temporary config.ini]
    write_file $config "\[releases\]\nversion=1.3.0\nchecksums_file=$manifest\n\n\[redis\]\nport=$cachePort\nssl=false\n"
    # The test owns the cache; application launchers only use its explicit INI settings.
    set server [expr {[info exists ::env(VALKEY_SERVER)] ? $::env(VALKEY_SERVER) : "valkey-server"}]
    set cacheProcess [::test_support::start [list $server --bind 127.0.0.1 --port $cachePort \
        --save {} --appendonly no --dir $temporary] [file join $temporary valkey.log]]
    ::test_support::wait_port $cachePort $cacheProcess
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
    package require valkey
    set cache [valkey -host localhost -port $cachePort]
    try {
        assert {[$cache PING] eq "PONG"}
        assert {[$cache LLEN history_events] > 0} {local requests must use Valkey monitoring}
    } finally {$cache destroy}
    assert {[string first {href="/blog"} $homepage] >= 0}
    assert {[string first {Sign Up} $homepage] < 0}
    set year "&#169; [clock format [clock seconds] -format %Y] JERILY LTD"
    assert {[string first $year $homepage] >= 0}
    # A new local runtime has no schema or imported catalog until explicitly patched.
    request /registry/search?q=web 503
    foreach {script task} {initdb-local task_initdb_website sync-local task_sync_website} {
        set result [::tjson::json_to_simple [exec {*}[auto_execok ttrek] run -script $script -- --lambda-port $lambdaPort]]
        assert {[dict get $result ok] && [dict get $result task] eq $task}
    }
    puts {PASS explicit local initialization and synchronization through Lambda}
    foreach path {/docs /docs/getting-started /blog} {
        assert {[::test_support::contains [request $path] $year]} $path
    }
    if {[info exists ::env(TTREK_BROWSER_TESTS)] && $::env(TTREK_BROWSER_TESTS) eq "1"} {
        set python [expr {[info exists ::env(PLAYWRIGHT_PYTHON)] ? $::env(PLAYWRIGHT_PYTHON) : "python3"}]
        exec $python [file join $root tests search_ui.py] $base >@stdout 2>@stderr
    }
    foreach {path expected} {
        /docs {Getting started} /blog {ttrek 1.0.0 is now public}
        /blog/2026-11-07-ttrek-100-is-now-public {Kostiantyn Kushnir}
        /docs/getting-started {ttrek init -y} /docs/registries private-ttrek-registry
        /docs/_assets/style.css .cards /packages tjson /search?q=web twebserver
        /registry/autocomplete?q=web twebserver /package/tcl 9.1.0
        /package/web-static-blog 0.1.0 /registry/web-static-wiki 0.1.0
        /package/treqmon 2.2.0 /registry/treqmon 2.2.0
        /registry/tcl 9.1.0 /registry/search?q=web twebserver
        /request-monitor data-chart-config /request-monitor/_assets/charts.js treqmon-chart-color
        /init TTREK_UPDATE_ROOT
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
    set asset [request /css/docs.css]
    assert {[dict get $asset body] eq $original}
    assert {[dict get $asset headers cache-control] eq "no-cache"}
    # trequests negotiates compression and decodes the body automatically.
    set wire_etag [dict get $asset headers etag]
    set manifest [::tjson::json_to_simple [encoding convertfrom utf-8 [read_file [file join $root public asset-manifest.json]]]]
    set versioned [dict get $manifest /css/docs.css]
    regexp {\.([0-9a-f]{16})\.css$} $versioned -> hash
    set etag "\"sha256-$hash\""
    set immutable [request $versioned]
    assert {[dict get $immutable headers cache-control] eq "public, max-age=31536000, immutable"}
    assert {[dict get $immutable body] eq $original}
    set head [request $versioned 200 HEAD]
    assert {[dict get $head body] eq {} && [dict get $head headers etag] eq $wire_etag}
    # Both API Gateway payload versions must preserve validators and empty 304s.
    set event [dict create httpMethod {S GET} path [list S $versioned] \
        headers [list M [dict create If-None-Match [list S "\"old\", W/$etag"]]]]
    assert {[invoke $event 304] eq {}}
    set event2 [dict create version {S 2.0} rawPath [list S $versioned] rawQueryString {S {}} \
        requestContext {M {http {M {method {S HEAD}}}}} headers [list M [dict create if-none-match [list S $etag]]]]
    assert {[invoke $event2 304] eq {}}
    dict set event headers {M {Accept-Encoding {S gzip}}}
    dict set event path [list S [dict get $manifest /css/site.css]]
    set zipped [invoke $event]
    set combined [read_file [file join $root public css site.css]]
    assert {[zlib gunzip $zipped] eq $combined}
    regexp {\.([0-9a-f]{16})\.css$} [dict get $manifest /css/site.css] -> hash
    dict set event headers [list M [dict create Accept-Encoding {S gzip} \
        If-None-Match [list S "\"sha256-$hash-gzip\""]]]
    assert {[invoke $event 304] eq {}}
    dict set event headers [list M [dict create If-None-Match [list S $etag]]]
    set changed "$original\n/* served from mock S3 */\n"
    request $s3/ttrek-assets/css/docs.css 200 PUT $changed text/css
    set updated [request /css/docs.css]
    assert {[dict get $updated body] eq $changed && [dict get $updated headers etag] eq $wire_etag}
    dict set event path {S /css/docs.css}
    assert {[invoke $event 304] eq {}}
    dict set event headers {M {}}
    assert {[invoke $event] eq $changed}
    assert {[dict get [request $versioned] body] eq $original}
    request $s3/ttrek-assets$versioned 200 PUT $changed text/css
    set updated [request $versioned]
    assert {[dict get $updated body] eq $changed && [dict get $updated headers etag] eq $wire_etag}
    assert {[dict get $updated headers cache-control] eq "public, max-age=31536000, immutable"}
    puts {PASS asset cache policies, gzip, manifest ETags and conditional GET/HEAD}
    set bytes {}
    for {set i 0} {$i < 256} {incr i} {lappend bytes $i}
    set binary [binary format c* [concat $bytes $bytes $bytes $bytes $bytes]]
    request $s3/ttrek-local/binary.bin 200 PUT $binary
    assert {[dict get [request $s3/ttrek-local/binary.bin] body] eq $binary}
    puts {PASS S3-backed website assets and binary object storage}

    set release [lindex [glob -directory [file join $seedSource ttrek-local ttrek 1.3.0] */ttrek] 0]
    set target [file tail [file dirname $release]]
    set download [dict get [request /dist/$target/ttrek] body]
    assert {[sha256 $download] eq [sha256 [read_file $release]]}
    set metadata [json [request /releases/latest/$target]]
    assert {[dict get $metadata sha256] eq [sha256 $download]}
    assert {[string first $s3/ttrek-local/ [dict get $metadata url]] == 0}
    puts {PASS signed release redirect, exact executable bytes and checksum metadata}
    request $s3/ttrek-local/ttrek/1.3.0/$extraTarget/ttrek 200 PUT $extraBinary
    set download [dict get [request /dist/$extraTarget/ttrek] body]
    set metadata [json [request /releases/latest/$extraTarget]]
    assert {$download eq $extraBinary && [dict get $metadata sha256] eq $extraChecksum}
    assert {[dict get $metadata version] eq "1.3.0"}
    puts {PASS configured local checksum manifest takes precedence over seed and production hashes}

    ::test_support::stop $process
    assert {![llength [glob -nocomplain -directory $state *]]} {temporary service directories were not cleaned}
    assert {[sha256 [read_file $archive]] eq $before} {archive changed during the test}
    foreach selected [list $port $lambdaPort $s3Port] {assert {![::test_support::port_open $selected]} {service left running}}
    assert {[::test_support::running $cacheProcess] && [::test_support::port_open $cachePort]} \
        {the launcher must leave the configured Valkey service running}
    puts {PASS clean shutdown and unchanged archive}
} on error {message options} {
    if {[info exists log] && [file exists $log]} {puts stderr [read_file $log]}
    return -options $options $message
} finally {
    try {::test_support::stop $process} finally {
        try {::test_support::stop $cacheProcess} finally {file delete -force $temporary}
    }
}
