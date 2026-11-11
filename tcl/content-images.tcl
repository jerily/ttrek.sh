namespace eval ::content_images {variable clients {}}

# The host owns one SDK client per settings dictionary in each worker. Both
# packages borrow it; credentials come from the SDK's refreshing provider chain.
proc ::content_images::options {settings} {
    variable clients
    if {[dict get $settings bucket] eq {}} {return {}}
    package require awss3 1.0.17
    set clientSettings [dict create region [dict get $settings region]]
    set endpoint [dict get $settings endpoint]
    if {$endpoint ne {}} {
        dict set clientSettings endpoint $endpoint
        dict set clientSettings aws_access_key_id local
        dict set clientSettings aws_secret_access_key local
    }
    if {![dict exists $clients $clientSettings]} {
        dict set clients $clientSettings [::aws::s3::create $clientSettings]
    }
    set s3 [dict create client [dict get $clients $clientSettings] bucket [dict get $settings bucket] \
        prefix [dict get $settings prefix] url_expiry_seconds [dict get $settings url_expiry_seconds] \
        http_endpoint $endpoint]
    return [list -images-directory [dict get $settings directory] -s3 $s3]
}
