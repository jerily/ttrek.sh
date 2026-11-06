# The host owns identity, CSRF and the login challenge for its documentation.
namespace eval ::site::editor {}

proc ::site::editor::settings {enabled} {
    if {!$enabled} {return {}}
    if {[::app_config::mode] ne "LOCAL"} {error "editing requires ENV=LOCAL"}
    if {![info exists ::env(TTREK_EDITOR_PASSWORD)] || $::env(TTREK_EDITOR_PASSWORD) eq {}} {
        error "editing requires TTREK_EDITOR_PASSWORD"
    }
    set channel [open /dev/urandom rb]
    try {set bytes [read $channel 32]} finally {close $channel}
    if {[string length $bytes] != 32} {error "cannot obtain a random CSRF token"}
    return [dict create password $::env(TTREK_EDITOR_PASSWORD) csrf_secret [binary encode hex $bytes]]
}

proc ::site::editor::authorize {editor request context action path} {
    set expected "Basic [binary encode base64 -maxlen 0 [encoding convertto utf-8 admin:[dict get $editor password]]]"
    if {[dict exists $request headers]} {
        dict for {key value} [dict get $request headers] {
            if {[string equal -nocase $key authorization]} {return [expr {$value eq $expected}]}
        }
    }
    return 0
}

proc ::site::editor::csrf {editor action request context token} {
    set secret [dict get $editor csrf_secret]
    if {$action eq "issue"} {return $secret}
    expr {$secret ne {} && $token eq $secret}
}
