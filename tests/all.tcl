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
package require twebserver
package provide tratelimit 1.0.1
package require treqmon 2.1.0
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
proc telemetry_stats {args} {lmap {a b c d} $::test_stats {list $a $b $c $d}}

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

test releases-unsupported {Other targets emitted by the installer cannot select an incompatible binary} -body {
    set s3_calls {}
    set statuses {}
    foreach arch {
        i686-unknown-linux-gnu i686-unknown-linux-musl
        arm-unknown-linux-gnueabihf armv7-unknown-linux-musleabihf
        mips-unknown-linux-gnu mipsel-unknown-linux-gnu mips64el-unknown-linux-gnuabi64
        powerpc64le-unknown-linux-gnu s390x-unknown-linux-gnu
        riscv64gc-unknown-linux-gnu loongarch64-unknown-linux-gnu
        aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
        x86_64-unknown-freebsd x86_64-unknown-netbsd x86_64-unknown-dragonfly x86_64-unknown-illumos
        x86_64-pc-windows-gnu
    } {
        set ext [expr {[string match *windows* $arch] ? ".exe" : ""}]
        lappend statuses [dict get [get_dist_handler {} [dict create pathParameters [dict create arch $arch ext $ext]]] status]
    }
    list [lsort -unique $statuses] $s3_calls
} -result {404 {}}

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
    set saved_release_env [array get ::env ENV]
    set ::env(ENV) PROD
    set test_releases [::app_config::releases [dict create releases [dict create \
        bucket public-releases region us-east-1 version 1.1.0 prefix ttrek/1.1.0 \
        checksums_file [file join $root tests fixtures release-checksums.json]]]]
    set s3_url "https://public-releases.s3.amazonaws.com/ttrek?X-Amz-Signature=[string repeat a 64]"
} -body {
    set response [get_release_handler {} {pathParameters {target aarch64-apple-darwin}}]
    set metadata [::tjson::json_to_simple [dict get $response body]]
    list [dict get $response status] [dict get $metadata version] [dict get $metadata target] \
        [expr {[dict get $metadata sha256] eq [string repeat c 64]}] \
        [expr {[dict get $metadata url] eq $s3_url}] [dict get $response headers Cache-Control] \
        [lindex [lindex $s3_calls end] end]
} -cleanup {
    unset -nocomplain ::env(ENV)
    array set ::env $saved_release_env
} -result {200 1.1.0 macos-arm64 1 1 no-store ttrek/1.1.0/macos-arm64/ttrek}

test releases-6 {Metadata requires a published checksum and supported target} -body {
    list [dict get [get_release_handler {} {pathParameters {target linux-amd64-glibc}}] status] \
        [dict get [get_release_handler {} {pathParameters {target ../secret}}] status]
} -result {503 404}

test source-download-1 {Archive signing has its own expiry and filename is only log metadata} -setup {
    set test_releases [::app_config::releases {releases {bucket public-releases region eu-west-1 \
        prefix ttrek/1.0.0 source_prefix ttrek/sources url_expiry_seconds 120 source_url_expiry_seconds 60}}]
    set s3_calls {}
    set s3_url "https://public-releases.s3.eu-west-1.amazonaws.com/source?X-Amz-Signature=[string repeat a 64]"
    set artifact "aws-sdk-cpp-core-1.11.924-[string repeat b 64].archive"
} -body {
    get_dist_handler {} {pathParameters {arch linux-amd64-glibc ext {}}}
    set response [get_source_download_handler {} [dict create pathParameters [dict create artifact $artifact] \
        queryStringParameters [dict create filename "subdir/file name.tar.gz"]]]
    list [dict get $response status] [dict get $response headers Cache-Control] \
        [expr {[dict get $response headers Location] eq $s3_url}] \
        [lindex [lindex $s3_calls 0] 3] [lindex [lindex $s3_calls 1] 3] \
        [expr {[lindex [lindex $s3_calls 1] end] eq "ttrek/sources/$artifact"}]
} -result {302 no-store 1 120 60 1}

test source-download-2 {Invalid names cannot select arbitrary private objects} -body {
    set s3_calls {}
    set result {}
    foreach artifact [list ../private no-digest.archive "../x-[string repeat a 64].archive" \
        "x-[string repeat a 63].archive" "x-[string repeat a 64].tar.gz"] {
        lappend result [dict get [get_source_download_handler {} [dict create pathParameters [dict create artifact $artifact]]] status]
    }
    list $result $s3_calls
} -result {{404 404 404 404 404} {}}

test source-download-3 {Archive downloads fail closed if disabled or signing fails} -body {
    set req [dict create pathParameters [dict create artifact "s3-1.0.0-[string repeat a 64].archive"]]
    set test_releases [::app_config::releases {}]
    set s3_calls {}
    set disabled [get_source_download_handler {} $req]
    set untouched [expr {![llength $s3_calls]}]
    set test_releases [::app_config::releases {releases {bucket public-releases region eu-west-1}}]
    set s3_url https://example.com/unsigned
    set unsigned [get_source_download_handler {} $req]
    list [dict get $disabled status] $untouched [dict get $unsigned status] [dict get $unsigned headers Cache-Control]
} -result {503 1 503 no-store}

test source-download-4 {Archive expiry and prefix are independently validated} -body {
    list [catch {::app_config::releases {releases {source_url_expiry_seconds 0}}}] \
        [catch {::app_config::releases {releases {source_prefix ../private}}}] \
        [catch {::app_config::releases {releases {source_prefix {}}}}]
} -result {1 1 1}

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
} -result 11

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
    set packages [lmap name [list 123 {} {a&"<b>} Καλημέρα] {dict create name $name description {}}]
    set html [::views::render packages.html.jinja [dict create \
        title {S Packages} packages [::recipe_search::cards $packages]]]
    list [contains $html {>123</a>}] [contains $html {a&amp;&quot;&lt;b&gt;</a>}] \
        [contains $html {/package/a%26%22%3Cb%3E}] [contains $html {Καλημέρα</a>}]
} -result {1 1 1 1}

test templates-4 {Empty collections stay JSON arrays} -body {
    set json [::tjson::typed_to_json [list M [list names [::views::strings {}] stats [::views::platform_stats {}]]]]
    list [::tjson::json_to_typed $json] \
        [contains [::views::render packages.html.jinja [dict create title {S Packages} packages {L {}}]] {href="/package/}]
} -result {{M {names {L {}} stats {L {}}}} 0}

test templates-year {Copyright follows the clock for each render, including a warm worker across New Year} -setup {
    rename ::clock ::original_clock
    set test_year 2030
    proc ::clock {operation args} {
        if {$operation eq "seconds"} {return [::original_clock scan "$::test_year-01-15"]}
        ::original_clock $operation {*}$args
    }
} -body {
    set results {}
    foreach test_year {2030 2031} {
        lappend results [contains [body [get_index_page_handler {} {}]] "&#169; $test_year JERILY LTD"]
    }
    set results
} -cleanup {
    rename ::clock {}
    rename ::original_clock ::clock
    unset test_year
} -result {1 1}

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

test handlers-project-url {Overview shows the latest version's project URL with HTML escaping} -setup {
    set latest [file join $registry_fixture demo 2.0.0 ttrek.json]
    set original [readFile $latest]
    set channel [open $latest w]
    puts $channel {{"url":"https://example.org/project?x=\"quoted\"&y=<tag>","description":"Demo project"}}
    close $channel
} -body {
    set html [body [get_package_page_handler {} {pathParameters {package_name demo}}]]
    list [contains $html {<p>Demo project</p>}] \
        [contains $html {Project: <a href="https://example.org/project?x=&quot;quoted&quot;&amp;y=&lt;tag&gt;">https://example.org/project?x=&quot;quoted&quot;&amp;y=&lt;tag&gt;</a>}]
} -cleanup {
    writeFile $latest $original
} -result {1 1}

test handlers-project-url-invalid {Absent, non-string and unsafe URLs do not produce project links} -setup {
    set latest [file join $registry_fixture demo 2.0.0 ttrek.json]
    set original [readFile $latest]
} -body {
    set results {}
    foreach json {{{}} {{"url":null}} {{"url":42}} {{"url":"javascript:alert(1)"}} {{"url":"//example.org"}} {{"url":"https://"}}} {
        writeFile $latest $json
        lappend results [contains [body [get_package_page_handler {} {pathParameters {package_name demo}}]] {Project:}]
    }
    lsort -unique $results
} -cleanup {
    writeFile $latest $original
} -result 0

test handlers-tags {Overview and listing show escaped tag links} -setup {
    set latest [file join $registry_fixture demo 2.0.0 ttrek.json]
    set original [readFile $latest]
    set saved_entries $::recipe_search::entries
    set tags {json {xml&"<x>}}
    writeFile $latest [::tjson::typed_to_json [list M [dict create tags [::views::strings $tags]]]]
    dict set ::recipe_search::entries demo tags $tags
} -body {
    set results {}
    foreach response [list [get_package_page_handler {} {pathParameters {package_name demo}}] \
            [get_packages_page_handler {} {}]] {
        set html [body $response]
        lappend results [dict get $response status] [contains $html {href="/search?q=json"}] \
            [contains $html {xml&amp;&quot;&lt;x&gt;}] [contains $html {xml&"<x>}]
    }
    set results
} -cleanup {
    writeFile $latest $original
    set ::recipe_search::entries $saved_entries
} -result {200 1 1 0 200 1 1 0}

test handlers-tags-optional {Missing and empty tags keep overview and listing usable} -setup {
    set latest [file join $registry_fixture demo 2.0.0 ttrek.json]
    set original [readFile $latest]
    set saved_entries $::recipe_search::entries
    set ::recipe_search::entries {}
} -body {
    set results {}
    foreach json {{{}} {{"tags":[]}}} {
        writeFile $latest $json
        foreach response [list [get_package_page_handler {} {pathParameters {package_name demo}}] \
                [get_packages_page_handler {} {}]] {
            lappend results [dict get $response status] [contains [body $response] {class="package-tags"}]
        }
    }
    set results
} -cleanup {
    writeFile $latest $original
    set ::recipe_search::entries $saved_entries
} -result {200 0 200 0 200 0 200 0}

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

test handlers-6 {Static assets read exact bytes from the configured server root} -setup {
    file mkdir $fixture/public/css
    set channel [open $fixture/public/css/typebase.css wb]
    puts -nonewline $channel {body {color: red;}}
    close $channel
} -body {
    list [binary decode base64 [dict get [get_assets_handler {} {path /css/typebase.css}] body]] \
        [dict get [get_ttrek_init_handler {} {}] file] \
        [dict get [get_logo_handler {} {}] file]
} -result [list {body {color: red;}} $fixture/public/ttrek-init $fixture/www/plume.png]

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

test registry-dev-dependencies-1 {Version and recipe APIs expose only runtime dependencies} -setup {
    set directory [file join $registry_fixture dev-tool 1.0.0]
    file mkdir $directory
    set fp [open [file join $directory ttrek.json] w]
    puts $fp {{"dependencies":{"tcl":"^9.1.0","conditional":{"version":"^1.0.0","if":"+static"}},"devDependencies":{"mock":"^0.1.0"},"build":{"default":[]}}}
    close $fp
} -body {
    set versions [::tjson::json_to_simple [body [get_package_versions_handler {} {pathParameters {package_name dev-tool}}]]]
    set recipe [::tjson::json_to_simple [body [get_package_spec_handler {} [dict create pathParameters \
        {package_name dev-tool package_version 1.0.0 os Linux machine x86_64}]]]]
    list [expr {[dict get $versions 1.0.0] eq [dict get $recipe dependencies]}] \
        [dict exists $recipe dependencies mock] [dict get $recipe dependencies conditional if]
} -result {1 0 +static}

test registry-dev-dependencies-2 {A recipe with only development tools exposes no requirements} -setup {
    set directory [file join $registry_fixture dev-only 1.0.0]
    file mkdir $directory
    set fp [open [file join $directory ttrek.json] w]
    puts $fp {{"dependencies":{},"devDependencies":{"missing-test-tool":"^1.0.0"},"build":{"default":[]}}}
    close $fp
} -body {
    set versions [::tjson::json_to_simple [body [get_package_versions_handler {} {pathParameters {package_name dev-only}}]]]
    set recipe [::tjson::json_to_simple [body [get_package_spec_handler {} [dict create pathParameters \
        {package_name dev-only package_version 1.0.0 os Linux machine x86_64}]]]]
    list [dict get $versions 1.0.0] [dict get $recipe dependencies]
} -result {{} {}}

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

test registry-script-args-1 {API resolves literal presets before runtime arguments} -setup {
    set script_body {#!/bin/sh
for arg do printf '%s\n' "$arg"; done
}
    writeFile [file join $recipe_dir args.sh] $script_body
    set presets [list {} {two words} {café 世界} "one\ntwo" {'quoted'} {"double"} \
        {$(touch preset-injected)} {`touch preset-injected`} {; touch preset-injected} {*} --]
    set reference [list M [list file {S args.sh} args [list L [lmap arg $presets {list S $arg}]]]]
    writeFile [file join $recipe_dir ttrek.json] [::tjson::typed_to_json \
        [list M [list dependencies {M {}} scripts [list M [list demo $reference]] build {M {default {L {}}}}]]]
} -body {
    set response [get_package_spec_handler {} [dict create pathParameters \
        {package_name file-demo package_version 1.0.0 os Linux machine x86_64}]]
    set spec [::tjson::json_to_simple [body $response]]
    set resolved [dict get $spec scripts demo]
    set runtime [list runtime {} {two words}]
    set previous [pwd]
    try {
        cd $recipe_dir
        set output [exec -keepnewline sh -c $resolved -- {*}$runtime]
    } finally {cd $previous}
    list [dict get $response status] [string match "#!/bin/sh\n*" $resolved] \
        [expr {$output eq "[join [concat $presets $runtime] \n]\n"}] \
        [file exists [file join $recipe_dir preset-injected]]
} -result {200 1 1 0}

test registry-script-args-2 {Empty presets preserve bytes and scripts can omit a shebang or final newline} -body {
    set reference {M {file {S args.sh} args {L {}}}}
    lassign [resolve_recipe_scripts [list M [list demo $reference]] $recipe_dir] type scripts
    set results [list [expr {[lindex [dict get $scripts demo] 1] eq $script_body}]]
    foreach content [list {printf '%s\n' "$@"} {#!/bin/sh}] {
        writeFile [file join $recipe_dir plain.sh] $content
        set reference {M {file {S plain.sh} args {L {{S plain}}}}}
        lassign [resolve_recipe_scripts [list M [list demo $reference]] $recipe_dir] type scripts
        lappend results [exec sh -c [lindex [dict get $scripts demo] 1] -- tail]
    }
    set results
} -result [list 1 "plain\ntail" {}]

test registry-script-args-3 {Reject malformed preset arrays and unknown reference fields} -body {
    set errors {}
    foreach reference {
        {M {file {S args.sh} args {S bad}}}
        {M {file {S args.sh} args {NULL {}}}}
        {M {file {S args.sh} args {L {{N 1}}}}}
        {M {file {S args.sh} args {L {}} extra {B true}}}
    } {
        lappend errors [catch {resolve_recipe_scripts [list M [list demo $reference]] $recipe_dir}]
    }
    set errors
} -result {1 1 1 1}

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
