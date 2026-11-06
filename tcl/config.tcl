namespace eval ::app_config {}

proc ::app_config::mode {} {
    set mode PROD
    if {[info exists ::env(ENV)]} {set mode $::env(ENV)}
    if {$mode ni {LOCAL PROD}} {error "ENV must be LOCAL or PROD"}
    return $mode
}

proc ::app_config::load {root} {
    set mode [mode]
    if {$mode eq "LOCAL"} {
        set path [file join $root etc config.local.ini]
        if {![file exists $path]} {error "ENV=LOCAL requires etc/config.local.ini"}
        set config [::tconfig::read_config $path]
        dict set config redis host localhost
    } else {
        set encrypted [file join $root etc config.enc]
        set plain [file join $root etc config.ini]
        if {[file exists $encrypted]} {
            set config [::tconfig::load_config $encrypted]
        } elseif {[file exists $plain]} {
            set config [::tconfig::read_config $plain]
        } else {
            error "ENV=PROD requires etc/config.enc or etc/config.ini"
        }
    }
    if {[dict exists $config redis ssl_ca_file]} {
        set ca_file [dict get $config redis ssl_ca_file]
        if {$ca_file ne "" && [file pathtype $ca_file] eq "relative"} {
            dict set config redis ssl_ca_file [file normalize [file join $root $ca_file]]
        }
    }
    set registry_dir registry
    if {[dict exists $config registry directory]} {
        set registry_dir [dict get $config registry directory]
    }
    if {$registry_dir eq ""} {error "registry.directory must not be empty"}
    dict set config registry directory [file normalize [file join $root $registry_dir]]
    return $config
}

proc ::app_config::valkey {config} {
    set settings [dict merge [dict create username appuser timeout 5000 ssl true \
        ssl_ca_file /etc/ssl/certs/ca-certificates.crt] [dict get $config redis]]
    if {[mode] eq "PROD"} {
        dict set settings ssl true
    } else {
        dict set settings host localhost
    }
    if {![dict exists $settings password] || [dict get $settings password] eq ""} {
        if {[dict get $settings ssl]} {
            error "Set redis.password in the application configuration (production SSM: /ttrek_sh/prod/redis/password)"
        }
        dict unset settings password
        dict unset settings username
    }
    if {![dict get $settings ssl]} {
        foreach key {ssl_ca_file ssl_cert_file ssl_key_file} {
            dict unset settings $key
        }
    }
    return $settings
}

proc ::app_config::releases {config} {
    set settings [dict create bucket {} region {} prefix ttrek/1.0.0 version 1.0.0 url_expiry_seconds 300]
    if {[dict exists $config releases]} {
        set settings [dict merge $settings [dict get $config releases]]
    }
    if {[dict exists $settings endpoint] && [dict get $settings endpoint] ne ""} {
        if {[mode] ne "LOCAL" ||
            ![regexp {^http://(127\.0\.0\.1|localhost):[0-9]+$} [dict get $settings endpoint]]} {
            error "releases.endpoint is only supported for a loopback mock in LOCAL mode"
        }
    }
    set bucket [dict get $settings bucket]
    if {$bucket ne ""} {
        if {![regexp {^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$} $bucket]} {
            error "releases.bucket must be an S3 bucket name"
        }
        if {![regexp {^[a-z0-9-]+$} [dict get $settings region]]} {
            error "releases.region is required when releases.bucket is set"
        }
    }
    set expiry [dict get $settings url_expiry_seconds]
    if {![string is integer -strict $expiry] || $expiry < 1 || $expiry > 604800} {
        error "releases.url_expiry_seconds must be between 1 and 604800"
    }
    set prefix [string trim [dict get $settings prefix] /]
    if {![regexp {^[a-zA-Z0-9._/-]*$} $prefix] ||
        "." in [split $prefix /] || ".." in [split $prefix /]} {
        error "releases.prefix must be an S3 key prefix without dot segments"
    }
    dict set settings prefix $prefix
    if {![regexp {^[0-9]+\.[0-9]+\.[0-9]+$} [dict get $settings version]]} {
        error "releases.version must be a stable major.minor.patch version"
    }
    foreach target {linux-amd64-glibc linux-arm64-glibc linux-amd64-musl linux-arm64-musl macos-arm64 macos-x86_64 macos-universal2} {
        set key sha256_$target
        if {[dict exists $settings $key] && ![regexp {^[0-9a-fA-F]{64}$} [dict get $settings $key]]} {
            error "releases.$key must be a SHA-256 hex digest"
        }
    }
    return $settings
}

proc ::app_config::content {config} {
    set allow false
    if {[dict exists $config content allow_create]} {set allow [dict get $config content allow_create]}
    if {![string is boolean -strict $allow]} {error "content.allow_create must be a boolean"}
    return [dict create allow_create $allow]
}

# The local mock host needs only this public setting, without loading AWS clients.
proc ::app_config::content_from_ini {path} {
    package require inifile
    set comment [::ini::commentchar]
    set ini {}
    try {
        ::ini::commentchar #
        set ini [::ini::open $path r]
        return [content [dict create content [dict create allow_create [::ini::value $ini content allow_create false]]]]
    } finally {
        if {$ini ne {}} {::ini::close $ini}
        ::ini::commentchar $comment
    }
}
