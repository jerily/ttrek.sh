# Application policy; packaging and service mechanics live in tdevops.
::tdevops::configure {
    archive ttrek-sh.zip
    files {tcl www schemas public LICENSE etc/rds-global-bundle.pem etc/releases.json devops/prepare-lambda.tcl devops/stage-registry.tcl}
    lambda-config etc/lambda.json
    routes etc/routes.json
    content-collections {docs blog}
    prepare devops/prepare-lambda.tcl
    services {s3 lambda proxy}
    required-files {tcl/lambda.tcl content/docs/getting-started.md etc/releases.json}
    environment {TTREK_SITE_ZIP --zip TTREK_SITE_PORT --port
        TTREK_LAMBDA_PORT --lambda-port TTREK_LOCAL_DIR --state-dir}
    package-help devops/package-usage.txt
    local-help devops/local-usage.txt
    local-hook ::project_devops::local
}

namespace eval ::project_devops {}
proc ::project_devops::local {options work} {
    set root $::tdevops::root
    # Read public release settings from the checkout's local INI.
    source [file join $root tcl config.tcl]
    set configPath [file join $root etc config.local.ini]
    if {[info exists ::env(TTREK_LOCAL_CONFIG)] && $::env(TTREK_LOCAL_CONFIG) ne {}} {
        set configPath [file normalize $::env(TTREK_LOCAL_CONFIG)]
        if {![file isfile $configPath]} {error "local configuration does not exist: $configPath"}
    }
    if {[file isfile $configPath]} {set ::env(TTREK_LOCAL_CONFIG) $configPath}
    set ::env(TTREK_LOCAL_RUNTIME_DATA) [file join $work data]
    set ::env(TTREK_LOCAL_S3_ENDPOINT) http://127.0.0.1:[dict get $options --s3-port]
    set ::env(ENV) LOCAL
    set releases [::app_config::releases {}]
    if {[file isfile $configPath]} {set releases [::app_config::releases_from_ini $configPath $root]}
    # Seed binaries are only a fallback for targets without uploaded metadata.
    if {[dict get $releases version] eq "1.3.0" && [dict get $releases prefix] eq "ttrek/1.3.0"} {
        foreach binary [glob -nocomplain -directory [dict get $options --s3-dir] ttrek-local/ttrek/1.3.0/*/ttrek] {
            set target [file tail [file dirname $binary]]
            if {![dict exists $releases checksums $target]} {
                dict set releases checksums $target [lindex [exec sha256sum $binary] 0]
            }
        }
    }
    dict set releases checksums_file {}
    set ::env(TTREK_LOCAL_RELEASES) $releases
}

::tdevops::configure {package-hook ::project_devops::seed_s3}
proc ::project_devops::seed_s3 {options architecture} {
    set root $::tdevops::root
    set seed [file normalize [dict get $options --s3-dir]]
    # Seed data travels beside the archive; it contains public assets and a
    # local CLI build, never the host configuration or working databases.
    file mkdir $seed
    ::tdevops::lambda::copy_tree [file join $root public] [file join $seed ttrek-assets]
    set cli [auto_execok ttrek]
    if {$cli eq {}} {error "ttrek is required to seed the local release download"}
    set target linux-[expr {$architecture eq "x86_64" ? "amd64" : "arm64"}]-glibc
    set release [file join $seed ttrek-local ttrek 1.3.0 $target]
    file mkdir $release
    # Preserve binaries written by the release upload script across packaging.
    if {![file exists [file join $release ttrek]]} {
        file copy [lindex $cli 0] [file join $release ttrek]
    }
}
