package require Tcl 9.1
package require tcltest 2
namespace import ::tcltest::test

set root [file dirname [file dirname [file normalize [info script]]]]
set test_root $root
set test_stats {}
# Stub external services, but exercise the real handlers, serializer and renderer.
package provide twebserver 1.47.54
package provide tratelimit 1.0.1
package require treqmon 2.0.0
namespace eval ::twebserver {
    proc get_rootdir {} {return $::test_root}
    proc get_config_dict {} {return {tratelimit {} treqmon {}}}
    proc create_router {args} {uplevel 1 {set router test_router}}
    proc add_middleware {args} {}
    proc add_route {args} {}
    proc get_path_param {request name} {return [dict get $request pathParameters $name]}
    proc base64_encode {value} {binary encode base64 $value}
    proc build_response {args} {
        if {[lindex $args 0] eq "-return_file"} {
            return [dict create status [lindex $args 1] file [lindex $args 3]]
        }
        lassign $args status type body
        return [dict create status $status type $type body $body]
    }
}
namespace eval ::tratelimit {proc init_middleware {config} {}}
namespace eval ::treqmon {proc init_middleware {config} {}}
source [file join $root tcl init-thread.tcl]
proc telemetry_event_common {args} {}
proc telemetry_sql {args} {return $::test_stats}

set fixture [::tcltest::makeDirectory registry-fixture]
file mkdir [file join $fixture registry demo 1.0.0]
file mkdir [file join $fixture registry demo 2.0.0]
file copy -force [file join $root tests fixtures ttrek.json] \
    [file join $fixture registry demo 1.0.0 ttrek.json]
set test_root $fixture

proc body {response} {dict get $response body}
proc contains {text fragment} {expr {[string first $fragment $text] >= 0}}

test templates-1 {All local templates validate including dependencies} -body {
    ::views::init [file join $root www]
    dict size $::views::templates
} -result 12

test templates-2 {Index layout and literal clipboard command} -body {
    set html [body [get_index_page_handler {} {}]]
    list [contains $html {<h1 class="splash-head">Install ttrek</h1>}] \
        [contains $html {data-clipboard-text="curl --proto &#39;=https&#39; --tlsv1.2 -sSf https://ttrek.sh/init | sh"}] \
        [contains $html {<title>ttrek: registry, website, and command-line interface</title>}]
} -result {1 1 1}

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
    set test_root $root
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
    set test_root $fixture
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
    set test_root $root
} -body {
    set response [get_package_spec_handler {} [dict create pathParameters \
        {package_name tink-cc package_version 2.1.1 os Linux machine x86_64}]]
    set spec [::tjson::json_to_simple [body $response]]
    set patch [binary decode base64 [dict get $spec patches rapidjson-1.1.0.diff]]
    list [dict get $response status] \
        [contains $patch {GenericStringRef& operator=}] [llength [dict get $spec install_script]]
} -cleanup {
    set test_root $fixture
} -result {200 1 7}

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
set failed $::tcltest::numTests(Failed)
::tcltest::cleanupTests
exit [expr {$failed > 0}]
