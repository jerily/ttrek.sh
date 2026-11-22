#
# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.
#

source [file join [file dirname [info script]] private-config.tcl]

namespace eval ::app_config {
    variable directory [file dirname [file normalize [info script]]]
}

# Select and validate the deployment environment.
proc ::app_config::mode {} {
    set mode PROD
    if {[info exists ::env(ENV)]} {set mode $::env(ENV)}
    if {$mode ni {LOCAL PROD}} {error "ENV must be LOCAL or PROD"}
    return $mode
}

# Load the environment-specific application configuration.
proc ::app_config::load {root} {
    set mode [mode]
    if {$mode eq "LOCAL"} {
        set path [file join $root etc config.local.ini]
        if {![file exists $path]} {error "ENV=LOCAL requires etc/config.local.ini"}
        set config [::tconfig::read_config $path]
        if {[dict exists $config redis]} {dict set config redis host localhost}
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
    if {[dict exists $config releases checksums_file] && [dict get $config releases checksums_file] ne {}} {
        dict set config releases checksums_file [file normalize [file join $root [dict get $config releases checksums_file]]]
    }
    return $config
}

# Validate the selected Valkey connection settings.
proc ::app_config::valkey {config} {
    if {![dict exists $config redis]} {
        error {Application configuration requires a [redis] section}
    }
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

# Reuse the existing cache and permit explicit ranking threshold overrides.
proc ::app_config::package_tracker {config} {
    set settings [dict create valkey [valkey $config]]
    if {[dict exists $config package_tracker]} {
        set thresholds [dict get $config package_tracker]
        dict for {key value} $thresholds {
            if {$key ni {min_current min_previous min_delta min_growth} ||
                    ![string is integer -strict $value] || $value < 1} {
                error "Invalid package_tracker.$key"
            }
        }
        dict set settings thresholds $thresholds
    }
    return $settings
}

# Backend selection belongs to the environment, never to an INI override.
proc ::app_config::telemetry {config root {localDirectory {}}} {
    if {[mode] eq "LOCAL"} {
        if {$localDirectory eq {}} {set localDirectory [file join $root data]}
        file mkdir $localDirectory
        return [dict create dialect sqlite database [file join $localDirectory telemetry.sqlite3] timeout 5000]
    }
    foreach key {host database username password} {
        if {![dict exists $config postgres $key] || [dict get $config postgres $key] eq {}} {
            error "Set postgres.$key in production configuration (SSM: /ttrek_sh/prod/postgres/$key)"
        }
    }
    set settings [dict merge {port 5432 timeout 5000} [dict get $config postgres]]
    # libpq reads this when connecting; TDBC has no -sslrootcert option.
    if {![info exists ::env(PGSSLROOTCERT)]} {
        set ::env(PGSSLROOTCERT) [file join $root etc rds-global-bundle.pem]
    }
    return [dict create dialect postgresql database [dict get $settings database] \
        host [dict get $settings host] port [dict get $settings port] \
        user [dict get $settings username] password [dict get $settings password] \
        timeout [dict get $settings timeout] sslmode verify-full]
}

# Only encrypted production configuration is allowed into a Lambda artifact.
proc ::app_config::validate_lambda_config {path} {
    package require tconfig::decrypt
    set config [::tconfig::read_config $path]
    foreach keys {{tconfig tink_keyset} {redis enc:password} {redis host} \
        {postgres enc:password} {postgres host} {postgres database} {postgres username}} {
        if {![dict exists $config {*}$keys] || [dict get $config {*}$keys] eq {}} {
            error "Production configuration requires [join $keys .] from tconfig/SSM"
        }
    }
    if {[dict exists $config redis password] || [dict exists $config postgres password] || [dict exists $config ssl]} {
        error "Production Lambda configuration must not contain plaintext passwords or TLS private keys"
    }
    if {[dict exists $config account]} {
        foreach name {aead_keyset mac_keyset email_hash_salt} {
            if {![dict exists $config account enc:$name] || [dict get $config account enc:$name] eq {} ||
                ([dict exists $config account $name] && [dict get $config account $name] ne {})} {
                error "Production account.$name must be encrypted from SSM"
            }
        }
        if {[dict exists $config account email_enabled] && [dict get $config account email_enabled] &&
            [dict exists $config account email_queue_enabled] && [dict get $config account email_queue_enabled]} {
            set queueUrl {}
            foreach name {email_queue_url enc:email_queue_url} {
                if {[dict exists $config account $name]} {append queueUrl [string trim [dict get $config account $name]]}
            }
            if {$queueUrl eq {}} {
                error "Production account.email_queue_url is required from SSM: /ttrek_sh/prod/account/email_queue_url"
            }
        }
    }
    if {[dict get $config redis host] in {localhost 127.0.0.1 ::1}} {
        error "Production redis.host must be the ElastiCache endpoint"
    }
}

# Load Lambda settings without permitting a production fallback.
proc ::app_config::lambda_config {root} {
    package require tconfig::decrypt
    if {[mode] eq "PROD"} {
        set path [file join $root etc config.ini]
        validate_lambda_config $path
        return [::tconfig::load_config $path]
    }
    set path [file join $root etc config.local.ini]
    if {[info exists ::env(TTREK_LOCAL_CONFIG)] && $::env(TTREK_LOCAL_CONFIG) ne {}} {
        set path $::env(TTREK_LOCAL_CONFIG)
        if {![file isfile $path]} {error "Local configuration does not exist: $path"}
    }
    if {[file isfile $path]} {return [::tconfig::read_config $path]}
    return {}
}

# Merge the request-monitor display settings.
proc ::app_config::request_monitor {config} {
    set settings [dict create master_template request-monitor-master.html.jinja]
    if {[dict exists $config request_monitor]} {
        set settings [dict merge $settings [dict get $config request_monitor]]
    }
    return $settings
}

# Validate and build the request-monitor storage configuration.
proc ::app_config::monitor_store {config} {
    set settings [dict merge {history_max_events 100000 store valkey} [request_monitor $config]]
    set history [dict get $settings history_max_events]
    if {![string is integer -strict $history] || $history < 1} {
        error "request_monitor.history_max_events must be a positive integer"
    }
    if {[dict get $settings store] ne "valkey"} {
        error "request_monitor.store must be valkey"
    }
    return [dict create valkeystore [dict merge [valkey $config] \
        [dict create history_max_events $history]]]
}

# Read route policy as data and reject invalid windows before serving traffic.
proc ::app_config::route_limits {{path {}}} {
    variable directory
    if {$path eq {}} {set path [file join $directory .. etc ratelimits.json]}
    package require tjson
    set channel [open $path r]
    try {
        chan configure $channel -encoding utf-8
        lassign [::tjson::json_to_typed [read $channel]] type routes
    } finally {close $channel}
    if {$type ne "M"} {error "ratelimits.json must contain an object"}
    set result {}
    dict for {name typedScopes} $routes {
        lassign $typedScopes type scopes
        if {$type ne "M"} {error "rate limits for $name must be an object"}
        dict for {scope typedSettings} $scopes {
            lassign $typedSettings type settings
            if {$scope ni {by_ip by_session} || $type ne "M"} {error "invalid rate-limit scope for $name: $scope"}
            if {[lsort [dict keys $settings]] ne {limit window_millis}} {
                error "rate limit $name.$scope requires window_millis and limit"
            }
            foreach key {window_millis limit} {
                lassign [dict get $settings $key] type value
                if {$type ne "N" || ![string is entier -strict $value] || $value < 1} {
                    error "rate limit $name.$scope.$key must be a positive integer"
                }
                dict set result $name $scope $key $value
            }
        }
    }
    return $result
}

# Shared policy for both the direct server and Lambda.
proc ::app_config::rate_limits {config store} {
    set limits [dict create window_millis 10000 limit 100]
    if {[dict exists $config ratelimit]} {set limits [dict merge $limits [dict get $config ratelimit]]}
    foreach key {window_millis limit} {
        set value [dict get $limits $key]
        if {![string is integer -strict $value] || $value < 1} {error "ratelimit.$key must be a positive integer"}
    }
    set routes [route_limits]
    return [dict create store $store global_limits [dict create by_ip $limits] route_limits $routes]
}

# Configure the environment-specific monitoring and rate-limit stores.
proc ::app_config::lambda_middleware {config} {
    # Validate limits before opening or validating backing services.
    rate_limits $config {}
    set monitorStore [monitor_store $config]
    if {[mode] eq "LOCAL"} {
        set rateStore {localstore {}}
    } else {
        set rateStore [dict create valkeystore [valkey $config]]
    }
    return [dict create \
        tratelimit [rate_limits $config $rateStore] \
        treqmon [dict create store $monitorStore]]
}

# Validate distribution settings and artifact checksums.
proc ::app_config::releases {config {root {}}} {
    set settings [dict create bucket {} region {} prefix ttrek/1.9.0 source_prefix ttrek/sources version 1.9.0 url_expiry_seconds 300 source_url_expiry_seconds 300 checksums_file {} checksums {}]
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
    foreach name {url_expiry_seconds source_url_expiry_seconds} {
        set expiry [dict get $settings $name]
        if {![string is integer -strict $expiry] || $expiry < 1 || $expiry > 604800} {
            error "releases.$name must be between 1 and 604800"
        }
    }
    foreach name {prefix source_prefix} {
        set prefix [string trim [dict get $settings $name] /]
        if {![regexp {^[a-zA-Z0-9._/-]*$} $prefix] ||
            "." in [split $prefix /] || ".." in [split $prefix /] ||
            ($name eq "source_prefix" && $prefix eq {})} {
            error "releases.$name must be an S3 key prefix without dot segments"
        }
        dict set settings $name $prefix
    }
    if {![regexp {^[0-9]+\.[0-9]+\.[0-9]+$} [dict get $settings version]]} {
        error "releases.version must be a stable major.minor.patch version"
    }
    if {[dict get $settings checksums_file] ne {}} {
        if {$root ne {}} {
            dict set settings checksums_file [file normalize [file join $root [dict get $settings checksums_file]]]
        }
        dict set settings checksums [release_checksums [dict get $settings checksums_file] [dict get $settings version]]
    }
    dict for {target checksum} [dict get $settings checksums] {
        if {$target ni {linux-amd64-glibc linux-arm64-glibc linux-amd64-musl linux-arm64-musl macos-arm64 macos-x86_64 macos-universal2} ||
            ![regexp {^[0-9a-fA-F]{64}$} $checksum]} {
            error "release checksums must map supported targets to SHA-256 hex digests"
        }
    }
    return $settings
}

# Read and validate checksums for the current release environment.
proc ::app_config::release_checksums {path version} {
    package require tjson
    set channel [open $path r]
    try {
        set manifest [::tjson::json_to_typed [read $channel]]
    } finally {close $channel}
    if {[lindex $manifest 0] ne "M"} {error "release checksums file must contain a JSON object"}
    set selected {}
    dict for {environment versions} [lindex $manifest 1] {
        if {$environment ni {local prod} || [lindex $versions 0] ne "M"} {
            error "release checksums must contain local/prod version objects"
        }
        dict for {release targets} [lindex $versions 1] {
            if {![regexp {^[0-9]+\.[0-9]+\.[0-9]+$} $release] || [lindex $targets 0] ne "M"} {
                error "release checksums must map stable versions to target objects"
            }
            dict for {target checksum} [lindex $targets 1] {
                if {$target ni {linux-amd64-glibc linux-arm64-glibc linux-amd64-musl linux-arm64-musl macos-arm64 macos-x86_64 macos-universal2} ||
                    [lindex $checksum 0] ne "S" || ![regexp {^[0-9a-fA-F]{64}$} [lindex $checksum 1]]} {
                    error "release checksums must map supported targets to SHA-256 strings"
                }
                if {$environment eq [string tolower [mode]] && $release eq $version} {
                    dict set selected $target [string tolower [lindex $checksum 1]]
                }
            }
        }
    }
    return $selected
}

# Read public settings without loading encrypted secrets or contacting KMS/SSM.
proc ::app_config::ini_section {path section} {
    package require tconfig::decrypt
    return [dict getdef [::tconfig::read_config $path] $section {}]
}

# Read only the public release settings for the local mock stack.
proc ::app_config::releases_from_ini {path root} {
    set settings [ini_section $path releases]
    if {[dict exists $settings checksums_file] && [dict get $settings checksums_file] ne {}} {
        dict set settings checksums_file [file normalize [file join $root [dict get $settings checksums_file]]]
    }
    return [releases [dict create releases $settings]]
}

# Read public content-image settings from an INI section.
proc ::app_config::content_images_from_ini {path root} {
    return [content_images [dict create content_images [ini_section $path content_images]] $root]
}

# Private storage with separate local image roots for documentation and blog.
proc ::app_config::content_images {config root} {
    set settings [dict create bucket {} region {} docs_directory content/docs blog_directory content/blog prefix ttrek/content/images \
        url_expiry_seconds 3600 endpoint {} cloudfront_enabled false assets_prefix cdn]
    if {[dict exists $config content_images]} {
        dict for {name value} [dict get $config content_images] {
            if {![dict exists $settings $name]} {error "unknown content_images setting: $name"}
            dict set settings $name $value
        }
    }
    set bucket [dict get $settings bucket]
    if {$bucket ne {} && (![regexp {^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$} $bucket] ||
            ![regexp {^[a-z0-9-]+$} [dict get $settings region]])} {
        error "content_images requires a valid bucket and region"
    }
    set endpoint [dict get $settings endpoint]
    if {$endpoint ne {} && ([mode] ne "LOCAL" ||
            ![regexp {^http://(127\.0\.0\.1|localhost):[0-9]+$} $endpoint])} {
        error "content_images.endpoint is only supported for a loopback mock in LOCAL mode"
    }
    set expiry [dict get $settings url_expiry_seconds]
    if {![string is integer -strict $expiry] || $expiry < 1 || $expiry > 604800} {
        error "content_images.url_expiry_seconds must be between 1 and 604800"
    }
    foreach key {prefix assets_prefix} {
        set prefix [string trim [dict get $settings $key] /]
        if {$prefix eq {} || ![regexp {^[a-zA-Z0-9_-]+(/[a-zA-Z0-9_-]+)*$} $prefix]} {
            error "content_images.$key must be an S3 key prefix without empty or dot segments"
        }
        dict set settings $key $prefix
    }
    set enabled [dict get $settings cloudfront_enabled]
    if {![string is boolean -strict $enabled]} {error "content_images.cloudfront_enabled must be a boolean"}
    foreach key {docs_directory blog_directory} {
        if {[dict get $settings $key] eq {}} {error "content_images.$key must not be empty"}
        # Leave symlinks visible for the packages' image-directory validation.
        dict set settings $key [file join $root [dict get $settings $key]]
    }
    return $settings
}

# Separate account policy, delivery and persistent worker keys from site settings.
proc ::app_config::account {config root {localDirectory {}}} {
    package require web-user::config 1.0
    if {![llength [info commands ::accounts::local_keys]]} {source [file join $root tcl accounts.tcl]}
    set input {}
    if {[dict exists $config account]} {set input [dict get $config account]}
    set policy [dict create tenant ttrek.sh collect_names true password_min_length 6 registration_captcha true \
        email_verification_required true verification_emails_enabled true captcha_length 6 \
        captcha_letters true login_captcha_after 3 login_captcha_window 900 cleanup_grace_period 3600]
    set display [dict create prefix /user title {Your account} issuer ttrek.sh origin {} \
        email_enabled true email_login_enabled true login_after_email_verification true email_from noreply@ttrek.sh email_region eu-central-1 \
        email_queue_enabled false email_queue_url {} google_enabled false google_client_id {} google_redirect_uri {}]
    set policyKeys {db_dialect secure_cookies require_https_origin allow_oauth_http allow_loopback_origin show_verification_codes require_email_delivery aws_email_enabled tenant collect_names collect_display_name collect_username registration_captcha captcha_length captcha_letters captcha_ttl \
        email_verification_required verification_emails_enabled login_captcha_after login_captcha_window \
        bcrypt_cost password_min_length session_ttl persistent_session_ttl code_ttl challenge_ttl cleanup_grace_period throttle_window \
        browse_limit post_limit account_limit challenge_limit resend_cooldown totp_digits totp_period totp_algorithm totp_window form_max_bytes}
    set keys {}
    set secrets {google_client_secret {}}
    dict for {name value} $input {
        if {$name in {aead_keyset mac_keyset email_hash_salt}} {
            dict set keys $name $value
        } elseif {[dict exists $secrets $name]} {
            dict set secrets $name $value
        } elseif {$name in $policyKeys} {
            dict set policy $name $value
        } elseif {[dict exists $display $name]} {
            dict set display $name $value
        } else {error "Unknown account setting: $name"}
    }
    if {[mode] eq "LOCAL"} {
        if {$localDirectory eq {}} {set localDirectory [file join $root data]}
        set keys [dict merge [::accounts::local_keys $localDirectory] $keys]
    }
    foreach name {aead_keyset mac_keyset email_hash_salt} {
        if {![dict exists $keys $name] || [string trim [dict get $keys $name]] eq {}} {
            error "Set account.$name in private configuration (SSM: /ttrek_sh/prod/account/$name)"
        }
    }
    set groups {admin {} moderator {}}
    set permissions {admin {admin_dashboard.manage, forum.moderate, wiki.edit, blog.edit, users.manage, request_monitor.view} moderator forum.moderate}
    if {[dict exists $config groups]} {set groups [dict merge $groups [dict get $config groups]]}
    if {[dict exists $config permissions]} {set permissions [dict merge $permissions [dict get $config permissions]]}
    ::web::user::access_config $groups $permissions
    dict create policy $policy display $display secret_config [dict merge $keys $secrets] access [dict create groups $groups permissions $permissions]
}

proc ::app_config::forum {config} {
    set defaults {title {Community discussions} moderation false posting_captcha false page_size 20}
    if {[dict exists $config forum]} {
        dict for {name value} [dict get $config forum] {
            if {$name ni {title moderation posting_captcha page_size body_max_length title_max_length post_limit}} {
                error "Unknown forum setting: $name"
            }
            dict set defaults $name $value
        }
    }
    return $defaults
}

# Select loading policy before reading or decrypting application configuration.
proc ::app_config::loading {} {
    set mode lazy
    if {[info exists ::env(TTREK_LOADING)]} {set mode $::env(TTREK_LOADING)}
    if {$mode ni {lazy eager}} {error "TTREK_LOADING must be lazy or eager"}
    return $mode
}
