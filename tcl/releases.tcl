package require awss3 1.0.12

namespace eval ::releases {
    variable client {}
}

# Installer triples and release-directory names identify the same artifacts.
proc ::releases::artifact {target} {
    switch -- $target {
        x86_64-unknown-linux-gnu - linux-amd64-glibc {return linux-amd64-glibc}
        aarch64-unknown-linux-gnu - linux-arm64-glibc {return linux-arm64-glibc}
        x86_64-unknown-linux-musl - linux-amd64-musl {return linux-amd64-musl}
        aarch64-unknown-linux-musl - linux-arm64-musl {return linux-arm64-musl}
        aarch64-apple-darwin - macos-arm64 {return macos-arm64}
        x86_64-apple-darwin - macos-x86_64 {return macos-x86_64}
        universal2-apple-darwin - macos-universal2 {return macos-universal2}
        default {return {}}
    }
}

proc ::releases::signed_url {artifact} {
    set settings [dict get [::site::config] releases]
    set key "$artifact/ttrek"
    if {[dict get $settings prefix] ne ""} {
        set key "[dict get $settings prefix]/$key"
    }
    return [signed_key $key [dict get $settings url_expiry_seconds]]
}

proc ::releases::source_url {artifact} {
    if {![regexp {^[a-zA-Z0-9][a-zA-Z0-9._+-]{0,199}-[0-9a-f]{64}\.archive$} $artifact]} {
        error "Invalid source archive name"
    }
    set settings [dict get [::site::config] releases]
    return [signed_key "[dict get $settings source_prefix]/$artifact" [dict get $settings source_url_expiry_seconds]]
}

proc ::releases::signed_key {key expiry} {
    variable client
    set settings [dict get [::site::config] releases]
    if {$client eq ""} {
        # One client per worker; the SDK's default provider refreshes role credentials.
        set client_settings [dict create region [dict get $settings region]]
        if {[dict exists $settings endpoint] && [dict get $settings endpoint] ne ""} {
            dict set client_settings endpoint [dict get $settings endpoint]
            dict set client_settings aws_access_key_id local
            dict set client_settings aws_secret_access_key local
        }
        set client [::aws::s3::create $client_settings]
    }
    set url [::aws::s3::generate_presigned_url -method GET \
        -expire $expiry $client [dict get $settings bucket] $key]
    # The SDK can return an empty or unsigned URL when credentials are unavailable.
    set valid_origin [string match {https://*} $url]
    if {[dict exists $settings endpoint] && [dict get $settings endpoint] ne ""} {
        set valid_origin [string match "[dict get $settings endpoint]/*" $url]
    }
    if {!$valid_origin || [regexp {[\r\n]} $url] ||
        ![regexp {[?&]X-Amz-Signature=[0-9a-fA-F]{64}(&|$)} $url]} {
        error "S3 did not return a signed HTTPS URL"
    }
    return $url
}
