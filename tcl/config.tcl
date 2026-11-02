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
