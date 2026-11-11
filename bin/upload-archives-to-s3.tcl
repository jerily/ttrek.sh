package require tjson
package require twebserver

namespace eval ::archive_mirror {
    variable root [file dirname [file dirname [file normalize [info script]]]]
    variable counts {}
}

proc ::archive_mirror::log {level message} {
    set channel [expr {$level eq "WARN" ? "stderr" : "stdout"}]
    puts $channel "$level: $message"
    flush $channel
}

proc ::archive_mirror::usage {} {
    return {Usage: upload-archives-to-s3.sh [options] [REGISTRY_DIRECTORY]
  --dry-run         List URL/key mappings without AWS calls or downloads
  --bucket NAME     S3 bucket (default: jerily-ttrek-app)
  --prefix PREFIX   Source prefix (default: ttrek/sources)
  --region REGION   AWS_REGION, AWS_DEFAULT_REGION, or eu-central-1
  --help            Show this help

The registry defaults to the sibling ttrek-registry checkout. Uses the AWS CLI
credential chain, including AWS_PROFILE. Archive failures are logged and skipped.}
}

proc ::archive_mirror::options {arguments} {
    variable root
    set region eu-central-1
    foreach name {AWS_DEFAULT_REGION AWS_REGION} {
        if {[info exists ::env($name)] && $::env($name) ne {}} {set region $::env($name)}
    }
    set settings [dict create registry [file join [file dirname $root] ttrek-registry] \
        bucket jerily-ttrek-app prefix ttrek/sources region $region dry-run 0]
    set positional 0
    while {[llength $arguments]} {
        set argument [lindex $arguments 0]
        set arguments [lrange $arguments 1 end]
        switch -- $argument {
            --dry-run {dict set settings dry-run 1}
            --bucket - --prefix - --region {
                if {![llength $arguments]} {error "$argument requires a value"}
                dict set settings [string range $argument 2 end] [lindex $arguments 0]
                set arguments [lrange $arguments 1 end]
            }
            default {
                if {[string match -* $argument]} {error "Unknown option: $argument"}
                if {$positional} {error "Only one registry directory may be specified"}
                dict set settings registry $argument
                set positional 1
            }
        }
    }
    dict set settings prefix [string trim [dict get $settings prefix] /]
    set prefix [dict get $settings prefix]
    if {![regexp {^[a-zA-Z0-9._/-]+$} $prefix] || "." in [split $prefix /] || ".." in [split $prefix /]} {
        error "--prefix must be nonempty and contain no dot segments"
    }
    if {![regexp {^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$} [dict get $settings bucket]]} {
        error "--bucket must be an S3 bucket name"
    }
    return $settings
}

# Retain JSON types so malformed arrays, objects and URLs can be skipped safely.
proc ::archive_mirror::field {node name type} {
    if {[lindex $node 0] ne "M" || ![dict exists [lindex $node 1] $name]} {error "Missing $name"}
    lassign [dict get [lindex $node 1] $name] actual value
    if {$actual ne $type} {error "$name must have JSON type $type"}
    return $value
}

proc ::archive_mirror::require_commands {} {
    foreach command {aws curl} {
        if {[auto_execok $command] eq {}} {error "Required command not found: $command"}
    }
}

proc ::archive_mirror::run_command {command} {
    exec {*}$command 2>@1
}

proc ::archive_mirror::mirror {settings url key} {
    variable counts
    set bucket [dict get $settings bucket]
    set destination s3://$bucket/$key
    if {[dict get $settings dry-run]} {
        log PLAN "$url -> $destination"
        dict incr counts planned
        return
    }
    set aws [list aws --region [dict get $settings region] --cli-connect-timeout 30 --cli-read-timeout 60]
    if {![catch {run_command [list {*}$aws s3api head-object --bucket $bucket --key $key]} message]} {
        log EXISTS $destination
        dict incr counts existing
        return
    }
    # Permission, credential and connection errors do not prove an object is absent.
    if {![regexp {\((404|NoSuchKey|NotFound)\)} $message]} {
        error "Cannot check $destination: $message"
    }
    set channel [file tempfile archive]
    close $channel
    try {
        log DOWNLOAD "$url -> $destination"
        if {[catch {run_command [list curl --disable --fail --location --silent --show-error \
            --globoff --retry 2 --retry-delay 2 --connect-timeout 30 --max-time 1800 \
            --output $archive --url $url]} message]} {
            error "Download failed for $url: $message"
        }
        if {![file isfile $archive] || [file size $archive] == 0} {
            error "Download returned an empty archive for $url"
        }
        if {[catch {run_command [list {*}$aws s3 cp $archive $destination \
            --content-type application/octet-stream --only-show-errors]} message]} {
            error "Upload failed for $destination (source $url): $message"
        }
        dict incr counts uploaded
        log UPLOADED $destination
    } finally {file delete -force $archive}
}

proc ::archive_mirror::process_spec {settings path seenVar} {
    variable counts
    upvar 1 $seenVar seen
    set version [file tail [file dirname $path]]
    set package [file tail [file dirname [file dirname $path]]]
    set relative $package/$version/ttrek.json
    set recipe $package-$version
    if {[catch {
        if {![regexp {^[a-zA-Z0-9][a-zA-Z0-9._+-]{0,199}$} $recipe]} {
            error "Invalid recipe identifier for the fallback endpoint"
        }
        set channel [open $path r]
        try {
            chan configure $channel -encoding utf-8
            set spec [::tjson::json_to_typed [read $channel]]
        } finally {close $channel}
        set build [field $spec build M]
    } message]} {
        dict incr counts invalid
        log WARN "$relative: $message"
        return
    }
    # Registry resolution uses directory identity, even if JSON metadata is stale.
    if {[catch {list [field $spec name S] [field $spec version S]} identity] || $identity ne [list $package $version]} {
        log WARN "$relative: name/version metadata differs from directory; using $recipe"
    }
    dict for {variant steps} $build {
        if {[lindex $steps 0] ne "L"} {
            dict incr counts invalid
            log WARN "$relative: build.$variant must be an array"
            continue
        }
        set index -1
        # Include every platform and conditional download, regardless of this host.
        foreach step [lindex $steps 1] {
            incr index
            set context "$relative: build.$variant\[$index\]"
            if {[catch {field $step cmd S} command]} {
                dict incr counts invalid
                log WARN "$context: $command"
                continue
            }
            if {$command ne "download"} {continue}
            if {[catch {
                set url [field $step url S]
                if {$url eq {} || [regexp {[^\x21-\x7e]} $url]} {
                    error "Download URL must be nonempty ASCII without whitespace; percent-encode other characters"
                }
                # Match ttrek's byte-array SHA-256: literal URL, no trailing newline.
                set digest [string tolower [::twebserver::hex_encode [::twebserver::sha256 $url]]]
                set key [dict get $settings prefix]/$recipe-$digest.archive
            } message]} {
                dict incr counts failed
                log WARN "$context: $message"
                continue
            }
            if {[dict exists $seen $key]} {
                dict incr counts duplicates
                continue
            }
            dict set seen $key 1
            dict incr counts archives
            if {[catch {mirror $settings $url $key} message]} {
                dict incr counts failed
                log WARN "$context: $message"
            }
        }
    }
}

proc ::archive_mirror::main {arguments} {
    variable counts
    if {$arguments in {{--help} {-h}}} {puts [usage]; return}
    set settings [options $arguments]
    set registry [dict get $settings registry]
    if {![file isdirectory $registry]} {error "Registry directory does not exist: $registry"}
    set specs [lsort -ascii [glob -nocomplain -type f -directory $registry */*/ttrek.json]]
    if {![llength $specs]} {error "No <package>/<version>/ttrek.json files found in $registry"}
    if {![dict get $settings dry-run]} {
        require_commands
        set ::env(AWS_PAGER) {}
        set ::env(AWS_CLI_AUTO_PROMPT) off
    }
    set counts {archives 0 existing 0 uploaded 0 planned 0 duplicates 0 failed 0 invalid 0}
    set seen {}
    foreach path $specs {process_spec $settings $path seen}
    set summary [list specs=[llength $specs]]
    dict for {name count} $counts {lappend summary $name=$count}
    log SUMMARY [join $summary { }]
    # A partial mirror is useful: archive/spec failures have already been logged.
}

if {[file normalize [info script]] eq [file normalize $argv0]} {
    if {[catch {::archive_mirror::main $argv} message]} {
        puts stderr "ERROR: $message"
        exit 1
    }
}
