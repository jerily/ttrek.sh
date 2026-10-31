# Load real dependencies in a fresh interpreter, without opening service connections.
package require Tcl 9.1
set packages $argv
if {![llength $packages]} {
    set packages {
        twebserver thread sqlite3 jinja2 tjson valkey tink
        awskms awsssm awsdynamodb tconfig::decrypt tconfig::encrypt
        tratelimit treqmon tsession tsession-dynamodb
    }
}
set failed 0
foreach name $packages {
    if {[catch {package require $name} result]} {
        puts stderr "$name: $result"
        set failed 1
    } else {
        puts "$name: $result"
    }
}
if {!$failed && ![llength $argv]} {
    set keyset [::tink::register_keyset [::tink::aead::create_keyset AES256_GCM]]
    try {
        set encrypted [::tink::aead::encrypt $keyset {runtime check}]
        if {[::tink::aead::decrypt $keyset $encrypted] ne "runtime check"} {
            error "Tink encryption round trip failed"
        }
        puts "Tink encryption round trip: passed"
    } finally {
        ::tink::unregister_keyset $keyset
    }
}
exit $failed
