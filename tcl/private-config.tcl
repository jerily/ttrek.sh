# Private configuration is passed explicitly; public settings reject credentials.
namespace eval ::private_config {}
proc ::private_config::option {args} {
    if {$args eq {}} {return {}}
    if {[llength $args] != 2 || [lindex $args 0] ne "-secret_config"} {error "Expected -secret_config dictionary"}
    set value [lindex $args 1]
    dict size $value
    return $value
}
proc ::private_config::password {settings args} {
    if {[dict exists $settings password]} {error "password belongs in -secret_config"}
    set secret [option {*}$args]
    dict for {name value} $secret {
        if {$name ne "password"} {error "Unknown private connection setting: $name"}
        if {$value ne {}} {dict set settings password $value}
    }
    return $settings
}
proc ::private_config::site {args} {
    set secret [dict merge {account {} postgres {} redis {}} [option {*}$args]]
    foreach name [dict keys $secret] {if {$name ni {account postgres redis}} {error "Unknown private site setting: $name"}}
    foreach name {postgres redis} {password {} -secret_config [dict get $secret $name]}
    return $secret
}
# Explicitly partition the assembled bootstrap configuration before handing it
# to a server or worker. It is never used as a fallback by mounting APIs.
proc ::private_config::partition {settings} {
    set private {account {} postgres {} redis {}}
    if {[dict exists $settings account secret_config]} {
        dict set private account [dict get $settings account secret_config]
        dict unset settings account secret_config
    }
    foreach path {{content_database password} {package_tracker valkey password} {tratelimit store valkeystore password} {treqmon store valkeystore password}} {
        if {![dict exists $settings {*}$path]} {continue}
        set group [expr {[lindex $path 0] eq "content_database" ? "postgres" : "redis"}]
        set password [dict get $settings {*}$path]
        if {[dict exists $private $group password] && [dict get $private $group password] ne $password} {error "Conflicting private $group credentials"}
        dict set private $group password $password
        dict unset settings {*}$path
    }
    dict create config $settings secret_config $private
}
proc ::private_config::assert_public {settings} {
    foreach path {{account secret_config} {account keys} {content_database password} {package_tracker valkey password} {tratelimit store valkeystore password} {treqmon store valkeystore password}} {
        if {[dict exists $settings {*}$path]} {error "Private site values must be passed through -secret_config"}
    }
}
