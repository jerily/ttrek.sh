# 
# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.
# 

# Load real dependencies in a fresh interpreter, without opening service connections.
package require Tcl 9.1
set production [expr {$argv eq {--production}}]
set packages [expr {$production ? {} : $argv}]
if {![llength $packages]} {
    set packages {
        twebserver topenapi jinja2 tjson ttrie ttrigrams valkey tink
        thashlib pure-tcl-oauth2-core pure-tcl-oauth2-client pure-tcl-aws-s3 pure-tcl-aws-kms pure-tcl-aws-ssm tconfig::decrypt tconfig::encrypt
        tratelimit treqmon web-user web-forum tcaptcha tclgd pure-tcl-aws-ses pure-tcl-aws-sqs pure-tcl-aws-lambda
        web-static-wiki web-static-blog tgit2 tpersist tpathexp cmark_gfm
        trequests
    }
    if {$production} {
        lappend packages tpersist-postgresql tsession-postgres
    } else {
        lappend packages tpersist-sqlite tsession-sqlite mock-proxy-app mock-lambda-app mock-s3-app mock-ses-app
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
            tink {package require tink 20240704.0.3}
            tjson {package require tjson 1.0.30}
            tpersist {package require tpersist 0.1.8}
            jinja2 {package require jinja2 0.2.0}
            thashlib {package require thashlib 0.1.1}
            topenapi {package require topenapi 0.2.0}
            ttrie {package require ttrie 0.2.0}
            ttrigrams {package require ttrigrams 0.2.0}
            trequests {package require trequests 1.3.0}
            tdom {package require tdom 0.9.6}
            treqmon {package require treqmon 2.3.2}
            tratelimit {package require tratelimit 1.1.0}
            tpathexp {package require tpathexp 1.2.0}
            pure-tcl-aws-s3 {package require pure-tcl-aws-s3 1.0.0}
            pure-tcl-aws-kms - pure-tcl-aws-ssm - pure-tcl-aws-ses - pure-tcl-aws-sqs - pure-tcl-aws-lambda {package require $name 1.0.0}
            web-static-wiki {package require $name 0.1.12}
            web-static-blog {package require $name 0.1.11}
            web-user {package require $name 0.7.2}
            web-forum {package require $name 0.3.4}
            tcaptcha {package require $name 1.0.0}
            tconfig::decrypt - tconfig::encrypt {package require $name 1.0.2}
            default {package require $name}
        }
    } result]} {
        puts stderr "$name: $result"
        set failed 1
    } else {
        puts "$name: $result"
    }
}
# Reject native AWS clients accidentally loaded through another dependency.
foreach library [info loaded] {
    if {[regexp -nocase {aws[-_]sdk[-_]tcl} $library]} {
        puts stderr "Native AWS client loaded: $library"
        set failed 1
    }
}
if {!$failed && (![llength $argv] || $production)} {
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
