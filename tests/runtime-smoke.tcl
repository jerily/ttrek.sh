# Start a disposable direct server and an isolated TLS Valkey instance.
set root [file dirname [file dirname [file normalize [info script]]]]
source [file join $root tests support.tcl]
foreach helper {assert read_file write_file json} {interp alias {} $helper {} ::test_support::$helper}
set prefix [expr {[info exists ::env(TTREK_SITE_PREFIX)] ? $::env(TTREK_SITE_PREFIX) : [file join $root ttrek-venv local]}]
set valkey [expr {[info exists ::env(VALKEY_SERVER)] ? $::env(VALKEY_SERVER) : "valkey-server"}]
set tclsh [file join $prefix bin tclsh9.1]
lassign [::test_support::ports 3] httpPort httpsPort valkeyPort
set base http://127.0.0.1:$httpPort
set mode [expr {[info exists ::env(ENV)] ? $::env(ENV) : "LOCAL"}]
assert {$mode in {LOCAL PROD}} {ENV must be LOCAL or PROD}
if {$mode eq "PROD" && ![info exists ::env(TTREK_TEST_POSTGRES)]} {
    error "PROD smoke tests require TTREK_TEST_POSTGRES for a disposable PostgreSQL database and PGSSLROOTCERT for its CA"
}
set environment [dict create AWS_EC2_METADATA_DISABLED true ENV $mode TTREK_SITE_PREFIX $prefix \
    LD_LIBRARY_PATH $prefix/lib:$prefix/lib64]
set envCommand [list {*}[auto_execok env]]
dict for {key value} $environment {lappend envCommand $key=$value}
set app [::test_support::temporary [file join $root build] runtime-smoke-]
set appProcess {}
set valkeyProcess {}
proc request {path args} {
    if {![string match http* $path]} {set path $::base$path}
    ::test_support::request $path {*}$args
}
proc rank {match query} {
    set tier [lsearch -exact {exact prefix substring description fuzzy description-fuzzy} [dict get $match match]]
    set distance [expr {[dict exists $match distance] ? [dict get $match distance] : 0}]
    set coverage [expr {[dict exists $match coverage] ? -[dict get $match coverage] : 0}]
    set unmatched [expr {$tier in {1 2} ? [string length [dict get $match name]] - [string length $query] : 0}]
    list $tier $distance $coverage $unmatched [dict get $match name]
}
proc compare_matches {query left right} {
    set a [rank $left $query]
    set b [rank $right $query]
    for {set i 0} {$i < 4} {incr i} {
        if {[lindex $a $i] < [lindex $b $i]} {return -1}
        if {[lindex $a $i] > [lindex $b $i]} {return 1}
    }
    string compare [lindex $a 4] [lindex $b 4]
}
try {
    foreach name {app.tcl run.sh tcl www public schemas bin content} {file copy [file join $root $name] $app}
    write_file [file join $app app.tcl] [string map [list {$server_handle 4433} "\$server_handle $httpsPort" \
        {$server_handle 8080} "\$server_handle $httpPort"] [read_file [file join $app app.tcl]]]
    set registryDir {package registry}
    file copy [file join $root registry] [file join $app $registryDir]
    file delete -force [file join $app $registryDir .git]
    write_file [file join $app $registryDir tclx 1.0.0 ttrek.json] {{}}
    file mkdir [file join $app build] [file join $app etc]
    file link -symbolic [file join $app build install] $prefix
    exec {*}$envCommand [file join $prefix bin openssl] req -x509 -newkey rsa:2048 -config /dev/null \
        -nodes -keyout [file join $app key.pem] -out [file join $app cert.pem] -days 1 -subj /CN=localhost \
        -addext subjectAltName=DNS:localhost,IP:127.0.0.1 >[file join $app certificate.log] 2>@1
    set config [string map [list {{registry_dir}} $registryDir {{port}} $valkeyPort {{ca_file}} [file join $app cert.pem] \
        {{key}} [binary encode base64 -maxlen 0 [read_file [file join $app key.pem]]] \
        {{certificate}} [binary encode base64 -maxlen 0 [read_file [file join $app cert.pem]]]] \
        [read_file [file join $root tests fixtures local-config.ini.in]]]
    if {$mode eq "PROD"} {
        append config "\n\[postgres\]\n"
        foreach {name option} {host host port port database database username user password password} {
            append config "$name=[dict get $::env(TTREK_TEST_POSTGRES) $option]\n"
        }
    }
    write_file [file join $app etc [expr {$mode eq "LOCAL" ? "config.local.ini" : "config.ini"}]] $config
    if {$mode eq "PROD"} {
        # Provision fixtures explicitly, outside the request-serving process.
        source [file join $app tcl telemetry.tcl]
        ::telemetry::connect [dict merge {dialect postgresql} $::env(TTREK_TEST_POSTGRES)]
        try {
            ::telemetry::initdb
            ::telemetry::sync_registry_metadata [file join $app $registryDir]
            foreach {kind directory} {wiki docs blog blog} {
                package require web-static-$kind
                ::web::static::${kind}::initdb $::telemetry::connection
                set store [::web::static::${kind}::create -connection $::telemetry::connection -domain ttrek.sh \
                    -title [expr {$kind eq "wiki" ? "Documentation" : "Blog"}]]
                ::web::static::${kind}::sync $store [file join $app content $directory]
            }
        } finally {::telemetry::close}
    }
    write_file [file join $app users.acl] "user default off\nuser appuser on >tls-smoke-password ~* +@all\n"
    set valkeyProcess [::test_support::start [list $valkey --bind 127.0.0.1 --port 0 --tls-port $valkeyPort \
        --tls-cert-file [file join $app cert.pem] --tls-key-file [file join $app key.pem] \
        --tls-ca-cert-file [file join $app cert.pem] --tls-auth-clients no --aclfile [file join $app users.acl] \
        --save {} --appendonly no --dir $app] [file join $app valkey.log]]
    ::test_support::wait_port $valkeyPort $valkeyProcess
    set appProcess [::test_support::start [list [file join $app run.sh]] [file join $app app.log] $environment $app]
    ::test_support::wait_port $httpPort $appProcess
    set checks [dict create / [expr {$mode eq "LOCAL" ? "http://localhost:8080/init | ENV=LOCAL sh" : "https://ttrek.sh/init"}] \
        /packages jinja2-tcl /docs {Getting started} /blog {ttrek 1.0.0 is now public} \
        /docs/getting-started {ttrek init -y} /package/tcl 9.1.0 /package/tcl/9.1.0 tcl@9.1.0 \
        /package/tjson/1.0.26 tjson@1.0.26 /request-monitor data-chart-config \
        /js/chart.umd.js Chart.js /css/typebase.css Typebase /registry/tcl 9.1.0]
    dict for {path expected} $checks {
        assert {[::test_support::contains [request $path] $expected]} "unexpected response for $path"
        puts "PASS GET $path"
    }
    foreach {path status} {/dist/linux-amd64-glibc/ttrek 503 /releases/latest/linux-amd64-glibc 503 /dist/unknown/ttrek 404} {
        set response [request $path $status]
        if {$status == 503} {assert {[dict get $response headers cache-control] eq "no-store"}}
        puts "PASS GET $path: $status"
    }
    set cli [expr {[info exists ::env(TTREK_SEARCH_BINARY)] ? $::env(TTREK_SEARCH_BINARY) : [file join [file dirname $root] ttrek build ttrek]}]
    foreach query {tcl tcll web compression encrytion {web server} c++ { WEB } no-such-recipe-xyz} {
        set response [request /registry/search 200 GET {} {} [list -params [list q $query]]]
        assert {[string match application/json* [dict get $response headers content-type]]}
        set matches [json $response]
        assert {$matches eq [lsort -command [list compare_matches $query] $matches]} "incorrect rank order: $query"
        set names [lmap match $matches {dict get $match name}]
        foreach match $matches {assert {[dict exists $match description]}}
        assert {[llength [lsort -unique $names]] == [llength $names]}
        if {$query eq "web"} {
            set found [lsearch -exact $names twebserver]
            assert {$found >= 0 && [string first {web server} [dict get [lindex $matches $found] description]] >= 0}
            assert {"b" ni $names}
        } elseif {$query eq "tcl"} {
            assert {[dict get [lindex $matches 0] name] eq "tcl" && [dict get [lindex $matches 0] match] eq "exact"}
        } elseif {$query eq "encrytion"} {
            set found [lsearch -exact $names tink-tcl]
            assert {$found >= 0 && [dict get [lindex $matches $found] distance] == 1}
        } elseif {$query eq "no-such-recipe-xyz"} {assert {$matches eq {}}}
        if {[file isfile $cli]} {
            set output [exec -keepnewline {*}$envCommand $cli search -registry [file join $app $registryDir] $query 2>@stderr]
            set rows {}
            foreach line [split $output \n] {
                if {$line eq {}} {continue}
                set tab [string first \t $line]
                if {$tab < 0} {lappend rows [list $line {}]; continue}
                lappend rows [list [string range $line 0 [expr {$tab - 1}]] [string range $line [expr {$tab + 1}] end]]
            }
            set expected [lmap match $matches {list [dict get $match name] [dict get $match description]}]
            assert {[llength $rows] == [llength $expected]} "CLI result count differs: $query"
            foreach row $rows match $expected {
                assert {[lindex $row 0] eq [lindex $match 0] && [lindex $row 1] eq [lindex $match 1]} \
                    "CLI parity failed for $query: $row != $match"
            }
        }
        puts "PASS recipe search and available CLI parity: $query"
    }
    foreach suffix [list {} ?q= ?q=..%2Fetc ?q=web&q=server ?q=%7Bweb%20server%7D ?q=[string repeat a 256]] {
        request /registry/search$suffix 400
    }
    foreach query {web c++ no-such-recipe-xyz} {
        set options [list -params [list q $query]]
        set suggestions [json [request /registry/autocomplete 200 GET {} {} $options]]
        set matches [json [request /registry/search 200 GET {} {} $options]]
        assert {$suggestions eq [lmap match [lrange $matches 0 7] {dict create name [dict get $match name] description [dict get $match description]}]}
    }
    foreach path {/registry/autocomplete?q=web&q=tcl /registry/autocomplete?q= /search?q=%3Cscript%3E} {request $path 400}
    puts {PASS autocomplete HTTP contract and query validation}
    set telemetry {M {action {S install} outcome {S success} is_toplevel {BOOL 1} os {S Linux} arch {S x86_64}}}
    set valid [::tjson::typed_to_json $telemetry]
    set invalid [::tjson::typed_to_json [list M [dict replace [lindex $telemetry 1] is_toplevel {S true}]]]
    foreach {payload contentType expected} [list $valid application/json 200 $invalid application/json 400 \
        {{} trailing} application/json 400 $valid text/plain 400] {
        request /telemetry/collect/tcl/9.1.0 $expected POST $payload $contentType
    }
    puts {PASS telemetry request schemas and HTTP 400 errors}
    if {$mode eq "LOCAL"} {
        set url https://localhost:$httpsPort/
        set response [request $url 200 GET {} {} [list -cafile [file join $app cert.pem]]]
        assert {[::test_support::contains $response {Install ttrek}]}
        assert {[catch {request $url}]} {an untrusted certificate was accepted}
        set session [::trequests::session -cafile [file join $app cert.pem]]
        try {
            set response [$session get $url -timeout 5000]
            assert {[$response status_code] == 200}
            $response destroy
        } finally {$session destroy}
        puts {PASS HTTPS localhost with verified CA file, session inheritance and untrusted-CA rejection}
    }
    foreach action {verify disconnect} {
        exec {*}$envCommand $tclsh [file join $root tests cache-smoke.tcl] $app $action >@stdout 2>@stderr
    }
    assert {[::test_support::contains [request /request-monitor] data-chart-config]}
    exec {*}$envCommand $tclsh [file join $root tests cache-smoke.tcl] $app verify >@stdout 2>@stderr
    update
    assert {[string first {Error while accessing telemetry db} [read_file [file join $app app.log]]] < 0} {Telemetry SQL failed}
    puts "$mode startup, HTTP, TLS stores and reconnect checks passed"
} on error {message options} {
    update
    foreach name {app.log valkey.log} {
        if {[file exists [file join $app $name]]} {puts stderr [read_file [file join $app $name]]}
    }
    return -options $options $message
} finally {
    try {
        ::test_support::stop $appProcess 10000
    } finally {
        try {::test_support::stop $valkeyProcess 10000} finally {file delete -force $app}
    }
}
