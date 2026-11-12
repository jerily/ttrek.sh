# Two independent Lambda adapters must share limits and history over TLS Valkey.
set root [file dirname [file dirname [file normalize [info script]]]]
source [file join $root tests support.tcl]
foreach helper {assert read_file write_file} {interp alias {} $helper {} ::test_support::$helper}

if {[llength $argv] == 3 && [lindex $argv 0] eq "--worker"} {
    source [file join $root tests fixtures deny-thread.tcl]
    lassign $argv ignored configPath phase
    set ::env(ENV) PROD
    package require tconfig::decrypt
    package require http
    source [file join $root tcl config.tcl]
    source [file join $root tcl site.tcl]
    source [file join $root tcl lambda.tcl]
    set ::site::settings [::app_config::lambda_middleware [::tconfig::read_config $configPath]]
    ::tratelimit::init_middleware [dict get $::site::settings tratelimit]
    ::treqmon::init_middleware [dict get $::site::settings treqmon]
    set ::site_lambda::router [::tpathexp::router]
    $::site_lambda::router add GET / {apply {{request context params} {
        ::twebserver::build_response 200 text/plain ok
    }}} -strict true
    set event {{"version":"2.0","rawPath":"/","headers":{"x-forwarded-for":"198.51.100.99"},"requestContext":{"http":{"method":"GET","sourceIp":"203.0.113.17"}}}}
    set response [::tjson::json_to_simple [::site_lambda::handle $event {}]]
    if {$phase eq "first"} {
        assert {[dict get $response statusCode] == 200}
        assert {[llength [::treqmon::get_history_events]] == 1}
    } else {
        assert {[dict get $response statusCode] == 429} {limit was not shared between processes}
        assert {[llength [::treqmon::get_history_events]] == 1} {history was not shared between processes}
        # Changing a forwarded header cannot evade the gateway's source-IP limit.
        set event [string map {198.51.100.99 198.51.100.100} $event]
        set response [::tjson::json_to_simple [::site_lambda::handle $event {}]]
        assert {[dict get $response statusCode] == 429}
        set event [string map {203.0.113.17 203.0.113.18} $event]
        set response [::tjson::json_to_simple [::site_lambda::handle $event {}]]
        assert {[dict get $response statusCode] == 200}
        assert {[llength [::treqmon::get_history_events]] == 2}
    }
    exit
}

set valkey [expr {[info exists ::env(VALKEY_SERVER)] ? $::env(VALKEY_SERVER) : "valkey-server"}]
set temporary [::test_support::temporary [file join $root build] lambda-valkey-]
lassign [::test_support::ports 1] port
set process {}
try {
    exec openssl req -x509 -newkey rsa:2048 -config /dev/null -nodes \
        -keyout [file join $temporary key.pem] -out [file join $temporary cert.pem] \
        -days 1 -subj /CN=localhost -addext subjectAltName=DNS:localhost,IP:127.0.0.1 \
        >[file join $temporary certificate.log] 2>@1
    write_file [file join $temporary users.acl] "user default off\nuser appuser on >lambda-test-password ~* +@all\n"
    set process [::test_support::start [list $valkey --bind 127.0.0.1 --port 0 --tls-port $port \
        --tls-cert-file [file join $temporary cert.pem] --tls-key-file [file join $temporary key.pem] \
        --tls-ca-cert-file [file join $temporary cert.pem] --tls-auth-clients no \
        --aclfile [file join $temporary users.acl] --save {} --appendonly no --dir $temporary] \
        [file join $temporary valkey.log]]
    ::test_support::wait_port $port $process
    set config [file join $temporary config.ini]
    package require tconfig::decrypt
    ::tconfig::write_config [dict create redis [dict create host localhost port $port username appuser \
        password lambda-test-password ssl_ca_file [file join $temporary cert.pem]] \
        ratelimit {window_millis 60000 limit 1}] $config
    foreach phase {first second} {
        exec [info nameofexecutable] [info script] --worker $config $phase >@stdout 2>@stderr
    }
    puts {PASS shared production limits and request history across two processes, TLS and trusted gateway source IP}
} finally {
    try {::test_support::stop $process} finally {file delete -force $temporary}
}
