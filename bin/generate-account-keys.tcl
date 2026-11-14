# Generate new account secrets locally; the destination is supplied at runtime.
set usage {Usage: ttrek run -script generate-account-keys -- OUTPUT_DIRECTORY}
if {$argv in {{--help} {-h}}} {puts $usage; exit 0}
if {$argc != 1 || [lindex $argv 0] eq {}} {puts stderr $usage; exit 2}
set directory [file normalize [lindex $argv 0]]
if {[file exists $directory]} {
    puts stderr "Refusing to overwrite an existing directory or file: $directory"
    exit 1
}

package require tink
package require twebserver
set values [dict create \
    aead_keyset.json [::tink::aead::create_keyset AES256_GCM] \
    mac_keyset.json [::tink::mac::create_keyset HMAC_SHA256] \
    email_hash_salt.txt [binary encode hex [::twebserver::random_bytes 32]]]

file mkdir $directory
file attributes $directory -permissions 0700
dict for {name value} $values {
    set channel [open [file join $directory $name] {WRONLY CREAT EXCL} 0600]
    try {
        chan configure $channel -encoding utf-8 -translation lf
        puts -nonewline $channel $value
    } finally {close $channel}
}
foreach name [dict keys $values] {puts "Created [file join $directory $name]"}
