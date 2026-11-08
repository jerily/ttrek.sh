# Check the actual production ZIP, without decrypting config or connecting to AWS.
package require Tcl 9.1
set root [file dirname [file dirname [file normalize [info script]]]]
if {[llength $argv] != 1} {error "Usage: lambda-package.tcl ARCHIVE"}
set archive [file normalize [lindex $argv 0]]
set ::env(ENV) PROD

proc read_bytes {path} {
    set channel [open $path rb]
    try {read $channel} finally {close $channel}
}

set mount [zipfs mount $archive /ttrek-lambda-package-test]
try {
    source [file join $mount tcl config.tcl]
    set releases [::app_config::releases_from_ini [file join $mount etc config.ini] $mount]
    set manifest [file join $mount etc releases.json]
    if {[dict get $releases checksums_file] ne $manifest} {
        error "Packaged release settings must use the bundled etc/releases.json"
    }
    set expected [file join $root etc releases.json]
    if {[read_bytes $manifest] ne [read_bytes $expected]} {
        error "Packaged release manifest differs from the checkout"
    }
    set checksums [::app_config::release_checksums $expected [dict get $releases version]]
    if {[dict get $releases checksums] ne $checksums} {
        error "Packaged release settings did not load the production checksums"
    }
    foreach forbidden {etc/config.local.ini etc/config.enc} {
        if {[file exists [file join $mount $forbidden]]} {error "Unexpected host configuration in ZIP: $forbidden"}
    }
    puts "PASS packaged release configuration and manifest ([dict size $checksums] production targets)"
} finally {
    zipfs unmount $mount
}
