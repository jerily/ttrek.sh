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
    variable client
    set settings [dict get [::twebserver::get_config_dict] releases]
    if {$client eq ""} {
        # One client per worker; the SDK's default provider refreshes role credentials.
        set client [::aws::s3::create [dict create region [dict get $settings region]]]
    }
    set key "$artifact/ttrek"
    if {[dict get $settings prefix] ne ""} {
        set key "[dict get $settings prefix]/$key"
    }
    set url [::aws::s3::generate_presigned_url -method GET \
        -expire [dict get $settings url_expiry_seconds] $client [dict get $settings bucket] $key]
    # The SDK can return an empty or unsigned URL when credentials are unavailable.
    if {![string match {https://*} $url] || [regexp {[\r\n]} $url] ||
        ![regexp {[?&]X-Amz-Signature=[0-9a-fA-F]{64}(&|$)} $url]} {
        error "S3 did not return a signed HTTPS URL"
    }
    return $url
}
