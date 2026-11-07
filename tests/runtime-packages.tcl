# Load real dependencies in a fresh interpreter, without opening service connections.
package require Tcl 9.1
set packages $argv
if {![llength $packages]} {
    set packages {
        twebserver topenapi thread sqlite3 jinja2 tjson ttrie ttrigrams valkey tink
        awss3 awskms awsssm awsdynamodb tconfig::decrypt tconfig::encrypt
        tratelimit treqmon tsession tsession-dynamodb
        web-static-wiki web-static-blog tpersist tpathexp cmark_gfm tdbc::sqlite3
        mock-proxy-app mock-lambda-app mock-s3-app trequests
    }
}
set failed 0
foreach name $packages {
    if {[catch {
        switch -- $name {
            valkey {
                set version [package require valkey 1.0.3]
                if {![::valkey::pkgconfig get feature-ssl]} {error "valkey requires TLS support"}
                set version
            }
            tink {package require tink 20240704.0.1}
            topenapi {package require topenapi 0.2.0}
            ttrie {package require ttrie 0.2.0}
            ttrigrams {package require ttrigrams 0.2.0}
            trequests {package require trequests 1.1.0}
            treqmon {package require treqmon 2.0.0}
            tratelimit {package require tratelimit 1.0.1}
            awss3 - awskms - awsssm - awsdynamodb {package require $name 1.0.12}
            default {package require $name}
        }
    } result]} {
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
