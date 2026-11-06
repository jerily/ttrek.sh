package require Tcl 9.1
package require tcltest 2
namespace import ::tcltest::test

set root [file dirname [file dirname [file normalize [info script]]]]
set test_root $root
set test_registry [file join $root registry]
set test_stats {}
source [file join $root tcl config.tcl]
set test_releases [::app_config::releases {}]
# Stub external services, but exercise the real handlers, serializer and renderer.
package provide twebserver 1.47.54
package provide tratelimit 1.0.1
package require treqmon 2.0.0
namespace eval ::twebserver {
    proc get_rootdir {} {return $::test_root}
    proc get_config_dict {} {
        return [dict create tratelimit {} treqmon {} registry_dir $::test_registry releases $::test_releases]
    }
    proc create_router {args} {uplevel 1 {set router test_router}}
    proc add_middleware {args} {}
    proc add_route {args} {}
    proc get_path_param {request name} {return [dict get $request pathParameters $name]}
    proc get_query_param {request name} {
        if {[dict exists $request queryStringParameters $name]} {return [dict get $request queryStringParameters $name]}
        error "query parameter not found"
    }
    proc base64_encode {value} {binary encode base64 $value}
    proc build_response {args} {
        if {[lindex $args 0] eq "-return_file"} {
            return [dict create status [lindex $args 1] file [lindex $args 3]]
        }
        lassign $args status type body
        return [dict create status $status type $type body $body]
    }
    proc build_redirect {status location} {
        return [dict create status $status headers [dict create Location $location] body {}]
    }
}
namespace eval ::tratelimit {proc init_middleware {config} {}}
namespace eval ::treqmon {proc init_middleware {config} {}}
source [file join $root tcl site.tcl]
proc ::site::config {} {
    dict merge [dict create rootdir $::test_root] [::twebserver::get_config_dict]
}
::site::configure [::site::config]
proc telemetry_event_common {args} {}
proc telemetry_sql {args} {return $::test_stats}

source [file join $root tests search.test]
source [file join $root tests request-validation.test]

# Stub only AWS calls; retain the real distribution handler and key selection.
rename ::aws::s3::create ::aws::s3::real_create
rename ::aws::s3::generate_presigned_url ::aws::s3::real_generate_presigned_url
proc ::aws::s3::create {settings} {
    set ::s3_settings $settings
    return test_s3_client
}
proc ::aws::s3::generate_presigned_url {args} {
    lappend ::s3_calls $args
    if {$::s3_url eq "error"} {error "signer unavailable"}
    return $::s3_url
}

test releases-1 {Every installer triple and release directory signs the matching executable} -setup {
    set test_releases [::app_config::releases {releases {bucket public-releases region eu-west-1 prefix /ttrek/1.0.0/ url_expiry_seconds 120}}]
    set s3_calls {}
    set s3_url "https://public-releases.s3.eu-west-1.amazonaws.com/ttrek?X-Amz-Signature=[string repeat a 64]"
} -body {
    set result {}
    foreach {triple target} {
        x86_64-unknown-linux-gnu linux-amd64-glibc aarch64-unknown-linux-gnu linux-arm64-glibc
        x86_64-unknown-linux-musl linux-amd64-musl aarch64-unknown-linux-musl linux-arm64-musl
        aarch64-apple-darwin macos-arm64 x86_64-apple-darwin macos-x86_64
        universal2-apple-darwin macos-universal2
    } {
        foreach arch [list $triple $target] {
            set response [get_dist_handler {} [dict create pathParameters [dict create arch $arch ext {}]]]
            lappend result [expr {[dict get $response status] == 302 &&
                [dict get $response headers Location] eq $s3_url &&
                [dict get $response headers Cache-Control] eq "no-store" &&
                [lindex $s3_calls end] eq [list -method GET -expire 120 test_s3_client public-releases "ttrek/1.0.0/$target/ttrek"]}]
        }
    }
    list [lsort -unique $result] $s3_settings
} -result {1 {region eu-west-1}}

test releases-2 {Unknown targets, path traversal and extensions cannot sign arbitrary keys} -body {
    set s3_calls {}
    set result {}
    foreach {arch ext} {windows .exe ../../secret {} linux-amd64-glibc .exe linux-amd64-glibc /secret} {
        lappend result [dict get [get_dist_handler {} [dict create pathParameters [dict create arch $arch ext $ext]]] status]
    }
    list $result $s3_calls
} -result {{404 404 404 404} {}}

test releases-3 {Disabled downloads do not contact AWS} -setup {
    set test_releases [::app_config::releases {}]
    set s3_calls {}
} -body {
    set response [get_dist_handler {} {pathParameters {arch linux-amd64-glibc ext {}}}]
    list [dict get $response status] [dict get $response headers Cache-Control] $s3_calls
} -result {503 no-store {}}

test releases-4 {Invalid signing results never become redirects} -setup {
    set test_releases [::app_config::releases {releases {bucket public-releases region us-east-1}}]
} -body {
    set result {}
    foreach s3_url [list {} error https://example.com/unsigned "https://example.com/\r\nInjected: header" http://example.com/insecure] {
        lappend result [dict get [get_dist_handler {} {pathParameters {arch macos-arm64 ext {}}}] status]
    }
    set result
} -result {503 503 503 503 503}

test releases-5 {Metadata contains the configured version, target, checksum and signed URL} -setup {
    dict set test_releases sha256_linux-arm64-musl [string repeat B 64]
    set s3_url "https://public-releases.s3.amazonaws.com/ttrek?X-Amz-Signature=[string repeat a 64]"
} -body {
    set response [get_release_handler {} {pathParameters {target aarch64-unknown-linux-musl}}]
    set metadata [::tjson::json_to_simple [dict get $response body]]
    list [dict get $response status] [dict get $metadata version] [dict get $metadata target] \
        [expr {[dict get $metadata sha256] eq [string repeat b 64]}] \
        [expr {[dict get $metadata url] eq $s3_url}] [dict get $response headers Cache-Control]
} -result {200 1.0.0 linux-arm64-musl 1 1 no-store}

test releases-6 {Metadata requires a published checksum and supported target} -body {
    list [dict get [get_release_handler {} {pathParameters {target macos-arm64}}] status] \
        [dict get [get_release_handler {} {pathParameters {target ../secret}}] status]
} -result {503 404}

rename ::aws::s3::create {}
rename ::aws::s3::real_create ::aws::s3::create
rename ::aws::s3::generate_presigned_url {}
rename ::aws::s3::real_generate_presigned_url ::aws::s3::generate_presigned_url
set ::releases::client {}

test releases-7 {The real SDK generates a signed URL without an AWS request} -setup {
    set test_releases [::app_config::releases {releases {bucket public-releases region eu-west-1}}]
    set ::releases::client [::aws::s3::create {region eu-west-1 aws_access_key_id test aws_secret_access_key test}]
} -body {
    set url [::releases::signed_url linux-amd64-glibc]
    list [string match {https://public-releases.s3.eu-west-1.amazonaws.com/ttrek/1.0.0/linux-amd64-glibc/ttrek?*} $url] \
        [regexp {[?&]X-Amz-Expires=300(&|$)} $url] \
        [regexp {[?&]X-Amz-Signature=[0-9a-f]{64}(&|$)} $url]
} -cleanup {
    ::aws::s3::destroy $::releases::client
    set ::releases::client {}
} -result {1 1 1}

set fixture [::tcltest::makeDirectory registry-fixture]
set registry_fixture [::tcltest::makeDirectory {custom registry [data]}]
foreach version {1.0.0 2.0.0} {
    file mkdir [file join $registry_fixture demo $version]
    file copy -force [file join $root tests fixtures ttrek.json] \
        [file join $registry_fixture demo $version ttrek.json]
}
file copy -force [file join $root registry tink-cc 2.1.1 rapidjson-1.1.0.diff] \
    [file join $registry_fixture demo 2.0.0 rapidjson-1.1.0.diff]
set test_root $fixture
set test_registry $registry_fixture

proc body {response} {dict get $response body}
proc contains {text fragment} {expr {[string first $fragment $text] >= 0}}

test templates-1 {All local templates validate including dependencies} -body {
    ::views::init [file join $root www]
    dict size $::views::templates
} -result 13

test templates-2 {Index layout and literal clipboard command} -setup {
    set saved_env [array get ::env ENV]
    unset -nocomplain ::env(ENV)
} -body {
    set html [body [get_index_page_handler {} {}]]
    list [contains $html {<h1 class="splash-head">Install ttrek</h1>}] \
        [contains $html {data-clipboard-text="curl --proto &#39;=https&#39; --tlsv1.2 -sSf https://ttrek.sh/init | sh"}] \
        [contains $html {<title>ttrek: registry, website, and command-line interface</title>}]
} -cleanup {
    array set ::env $saved_env
} -result {1 1 1}

test templates-2-local {LOCAL installer command preserves local mode for the downloaded script} -setup {
    set saved_env [array get ::env ENV]
    set ::env(ENV) LOCAL
} -body {
    contains [body [get_index_page_handler {} {}]] {data-clipboard-text="curl -fsS http://localhost:8080/init | ENV=LOCAL sh"}
} -cleanup {
    unset -nocomplain ::env(ENV)
    array set ::env $saved_env
} -result 1

test templates-3 {Names remain strings; HTML and URL contexts are escaped} -body {
    set html [::views::render packages.html.jinja [dict create \
        title {S Packages} package_names [::views::strings [list 123 {} {a&"<b>} Καλημέρα]]]]
    list [contains $html {>123</a>}] [contains $html {a&amp;&quot;&lt;b&gt;</a>}] \
        [contains $html {/package/a%26%22%3Cb%3E}] [contains $html {Καλημέρα</a>}]
} -result {1 1 1 1}

test templates-4 {Empty collections stay JSON arrays} -body {
    set json [::tjson::typed_to_json [list M [list names [::views::strings {}] stats [::views::platform_stats {}]]]]
    list [::tjson::json_to_typed $json] \
        [contains [::views::render packages.html.jinja [dict create title {S Packages} package_names {L {}}]] {href="/package/}]
} -result {{M {names {L {}} stats {L {}}}} 0}

test handlers-1 {Package listing comes from the registry} -body {
    contains [body [get_packages_page_handler {} {}]] {href="/package/demo">demo</a>}
} -result 1

test handlers-2 {Version ordering and installation statistics survive JSON serialization} -setup {
    set test_stats {{linux & amd64} 3 2 1}
} -body {
    set html [body [get_package_page_handler {} {pathParameters {package_name demo}}]]
    list [expr {[string first {>2.0.0</a>} $html] < [string first {>1.0.0</a>} $html]}] \
        [contains $html {data-clipboard-text="ttrek install demo"}] \
        [contains $html {<td>linux &amp; amd64</td>}] [contains $html {<td>3</td>}]
} -cleanup {
    set test_stats {}
} -result {1 1 1 1}

test handlers-3 {Dependency conditions render on version pages} -body {
    set html [body [get_package_version_page_handler {} {pathParameters {package_name demo package_version 1.0.0}}]]
    list [contains $html {demo@1.0.0}] [contains $html {<td>tcl</td>}] \
        [contains $html {<td>^9.1.0</td>}] [contains $html {<td>+ssl</td>}] \
        [contains $html {Statistics (installations)}]
} -result {1 1 1 1 0}

test handlers-4 {Unknown package version still returns 404} -body {
    dict get [get_package_version_page_handler {} {pathParameters {package_name demo package_version missing}}] status
} -result 404

test handlers-5 {No dependencies or statistics means no empty tables} -body {
    set html [::views::render package-version.html.jinja [dict create \
        package_name {S demo} package_version {S 1.0.0} deps {L {}} stat_platforms {L {}}]]
    list [contains $html {Dependencies:}] [contains $html {Statistics (installations)}]
} -result {0 0}

test handlers-6 {Static paths use the server root without a template engine dependency} -body {
    list [dict get [get_assets_handler {} {path /css/typebase.css}] file] \
        [dict get [get_ttrek_init_handler {} {}] file] \
        [dict get [get_logo_handler {} {}] file]
} -result [list $fixture/public/css/typebase.css $fixture/public/ttrek-init $fixture/www/plume.png]

test registry-1 {Static options are conditional USE flags} -setup {
    set test_registry [file join $root registry]
} -body {
    set response [get_package_spec_handler {} [dict create pathParameters \
        {package_name jinja2-tcl package_version 0.1.0 os Linux machine x86_64}]]
    set spec [::tjson::json_to_simple [body $response]]
    set static_option 0
    foreach step [dict get $spec install_script] {
        if {[dict get $step cmd] ne "cmake_config"} {continue}
        foreach option [dict get $step options] {
            if {[dict get $option name] eq "BUILD_SHARED_LIBS" &&
                [dict get $option value] eq "OFF" && [dict get $option if] eq "+static"} {
                set static_option 1
            }
        }
    }
    list [dict get $response status] [expr {"+static" in [dict get $spec iuse]}] $static_option
} -cleanup {
    set test_registry $registry_fixture
} -result {200 1 1}

test registry-2 {Shared defaults remain unconditional before static overrides} -body {
    set result {}
    foreach {name version} {abseil-cpp 20230802.1.0 aws-sdk-cpp 1.11.157 protobuf 21.9.0} {
        set fp [open [file join $root registry $name $version ttrek.json]]
        set spec [::tjson::json_to_simple [read $fp]]
        close $fp
        set shared {}
        foreach step [dict get $spec build default] {
            if {[dict get $step cmd] ne "cmake_config"} {continue}
            foreach option [dict get $step options] {
                if {[dict get $option name] eq "BUILD_SHARED_LIBS"} {lappend shared $option}
            }
        }
        lappend result [list [dict get [lindex $shared 0] value] \
            [dict exists [lindex $shared 0] if] [dict get [lindex $shared 1] value] \
            [dict get [lindex $shared 1] if]]
    }
    set result
} -result {{ON 0 OFF +static} {ON 0 OFF +static} {ON 0 OFF +static}}

test registry-3 {Build recipes retain their embedded patches} -setup {
    set test_registry [file join $root registry]
} -body {
    set response [get_package_spec_handler {} [dict create pathParameters \
        {package_name tink-cc package_version 2.1.1 os Linux machine x86_64}]]
    set spec [::tjson::json_to_simple [body $response]]
    set patch [binary decode base64 [dict get $spec patches rapidjson-1.1.0.diff]]
    list [dict get $response status] \
        [contains $patch {GenericStringRef& operator=}] [llength [dict get $spec install_script]]
} -cleanup {
    set test_registry $registry_fixture
} -result {200 1 7}

test registry-4 {Version API reads dependencies from the configured directory} -body {
    set response [get_package_versions_handler {} {pathParameters {package_name demo}}]
    set versions [::tjson::json_to_simple [body $response]]
    list [dict get $response status] [dict keys $versions] \
        [dict get $versions 2.0.0 tcl]
} -result {200 {2.0.0 1.0.0} ^9.1.0}

test registry-scripts-1 {Recipe API preserves named script bodies exactly} -body {
    set fp [open [file join $registry_fixture demo 1.0.0 ttrek.json]]
    set recipe [::tjson::json_to_simple [read $fp]]
    close $fp
    set response [get_package_spec_handler {} [dict create pathParameters \
        {package_name demo package_version 1.0.0 os Linux machine x86_64}]]
    set spec [::tjson::json_to_simple [body $response]]
    list [dict get $response status] [dict get $spec version] \
        [expr {[dict get $spec scripts] eq [dict get $recipe scripts]}]
} -result {200 1.0.0 1}

test registry-scripts-2 {Recipes without scripts return an empty scripts object} -setup {
    file mkdir [file join $registry_fixture no-scripts 1.0.0]
    file copy -force [file join $root tests fixtures no-scripts.json] \
        [file join $registry_fixture no-scripts 1.0.0 ttrek.json]
} -body {
    set response [get_package_spec_handler {} [dict create pathParameters \
        {package_name no-scripts package_version 1.0.0 os Linux machine x86_64}]]
    ::tjson::parse [body $response] no_scripts_response
    list [dict get $response status] \
        [::tjson::to_typed [::tjson::get_object_item $no_scripts_response scripts]]
} -result {200 {M {}}}

test registry-script-files-1 {Recipe files preserve UTF-8, CRLF and final newline through the API} -setup {
    set recipe_dir [file join $registry_fixture file-demo 1.0.0]
    file mkdir $recipe_dir
    set script_body "#!/bin/sh\r\nprintf '%s\\n' 'café'\r\n"
    set fp [open [file join $recipe_dir demo.sh] wb]
    puts -nonewline $fp [encoding convertto utf-8 $script_body]
    close $fp
    set fp [open [file join $recipe_dir ttrek.json] w]
    puts $fp {{"dependencies":{},"scripts":{"demo":{"file":"demo.sh"},"inline":"echo inline"},"build":{"default":[]}}}
    close $fp
} -body {
    set response [get_package_spec_handler {} [dict create pathParameters \
        {package_name file-demo package_version 1.0.0 os Linux machine x86_64}]]
    set spec [::tjson::json_to_simple [body $response]]
    list [dict get $response status] [expr {[dict get $spec scripts demo] eq $script_body}] \
        [dict get $spec scripts inline]
} -result {200 1 {echo inline}}

test registry-script-files-2 {Reject missing files, paths and invalid reference objects} -body {
    set errors {}
    foreach reference [list {M {}} {M {file {N 42}}} {M {file {S demo.sh} extra {B true}}} \
            {M {file {S missing.sh}}} {M {file {S ../outside.sh}}} \
            {M {file {S /etc/passwd}}} {M {file {S .}}} {M {file {S ..}}}] {
        lappend errors [catch {resolve_recipe_scripts [list M [list demo $reference]] $recipe_dir}]
    }
    set errors
} -result {1 1 1 1 1 1 1 1}

test registry-script-files-3 {Reject symbolic links, directories and NUL bytes} -setup {
    file link -symbolic [file join $recipe_dir linked.sh] [file join $recipe_dir demo.sh]
    file mkdir [file join $recipe_dir folder.sh]
    set fp [open [file join $recipe_dir nul.sh] wb]
    puts -nonewline $fp "echo before\u0000echo after"
    close $fp
} -body {
    set errors {}
    foreach filename {linked.sh folder.sh nul.sh} {
        lappend errors [catch {resolve_recipe_scripts \
            [list M [list demo [list M [list file [list S $filename]]]]] $recipe_dir}]
    }
    set errors
} -result {1 1 1}

test registry-scripts-3 {Pinned OpenACS recipe exposes the installed-package entry points} -setup {
    set test_registry [file join $root registry]
} -body {
    set response [get_package_spec_handler {} [dict create pathParameters \
        {package_name openacs package_version 5.10.1 os Linux machine x86_64}]]
    set spec [::tjson::json_to_simple [body $response]]
    list [dict get $response status] [lsort [dict keys [dict get $spec scripts]]] \
        [contains [dict get $spec scripts init-local] {$PROJECT_INSTALL_DIR}]
} -cleanup {
    set test_registry $registry_fixture
} -result {200 {init-local start-local} 1}

test registry-5 {Latest recipe and patches use the configured directory with literal glob characters} -body {
    set response [get_package_spec_handler {} [dict create pathParameters \
        {package_name demo package_version latest os Linux machine x86_64}]]
    set spec [::tjson::json_to_simple [body $response]]
    set patch [binary decode base64 [dict get $spec patches rapidjson-1.1.0.diff]]
    list [dict get $response status] [dict get $spec version] \
        [contains $patch {GenericStringRef& operator=}]
} -result {200 2.0.0 1}

# A deterministic sample matching treqmon's public statistics shape.
proc monitor_stats {metric top_key} {
    set stats {}
    foreach {interval step} {second 1 minute 60 hour 3600} {
        dict set stats $interval [dict create xrange [list 0 [expr {2 * $step}]] \
            $metric [dict create $step [list $step 7]] $top_key [list [list $step 7]]]
    }
    return $stats
}
proc ::treqmon::get_history_events {} {return {}}
proc ::treqmon::get_summary {events} {
    return {last_minute_avg_response_time 0 last_half_hour_avg_response_time 1.5 last_hour_avg_response_time 2 last_day_avg_response_time 3}
}
proc ::treqmon::get_page_views {events} {monitor_stats page_views top_k_views}
proc ::treqmon::get_response_times {events} {monitor_stats response_times top_k_times}
proc ::treqmon::get_active_users {events} {monitor_stats active_users top_k_users}

test monitor-1 {Charts fill missing buckets with zero for every interval} -body {
    set result {}
    foreach interval {second minute hour} {
        set chart [::treqmon::view::chart [monitor_stats page_views top_k_views] $interval page_views {Page Views} Views top_k_views]
        set chart [::tjson::json_to_simple [::tjson::typed_to_json $chart]]
        set config [::tjson::json_to_simple [dict get $chart config]]
        lappend result [dict get [lindex [dict get $config data datasets] 0] data]
    }
    set result
} -result {{0 7 0} {0 7 0} {0 7 0}}

test monitor-2 {Monitor has six charts without a session package} -body {
    set html [body [get_stats_handler {} {}]]
    list [regexp -all {<canvas } $html] [contains $html {Last 30 minutes: 1.5}] \
        [contains $html {src="/js/chart.umd.js"}] [contains $html {&quot;type&quot;}] \
        [contains $html {Active Users}]
} -result {6 1 1 1 0}

test monitor-3 {Active user charts appear when sessions are present} -setup {
    package provide tsession 1.0.0
} -body {
    set html [body [get_stats_handler {} {}]]
    list [regexp -all {<canvas } $html] [contains $html {Active Users}]
} -cleanup {
    package forget tsession
} -result {9 1}

test templates-5 {Template data cannot execute Tcl or inject HTML} -body {
    set ::executed 0
    set html [::views::render package.html.jinja [dict create \
        package_name {S {[set ::executed 1]<script>"&}} versions {L {}} stat_platforms {L {}}]]
    list $::executed [contains $html {[set ::executed 1]&lt;script&gt;&quot;&amp;}] \
        [contains $html {<script>"&}]
} -result {0 1 0}

::tcltest::removeDirectory registry-fixture
::tcltest::removeDirectory {custom registry [data]}
set failed $::tcltest::numTests(Failed)
::tcltest::cleanupTests
exit [expr {$failed > 0}]
