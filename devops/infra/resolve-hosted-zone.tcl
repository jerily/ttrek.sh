#!/usr/bin/env tclsh
# Resolve a public Route 53 zone without requiring application packages.
package require Tcl 8.6 9.0

proc env_value {name default} {
    if {[info exists ::env($name)] && $::env($name) ne {}} {return $::env($name)}
    return $default
}

proc zone_id {value} {
    set prefix /hostedzone/
    if {[string first $prefix $value] == 0} {
        return [string range $value [string length $prefix] end]
    }
    return $value
}

proc resolve {} {
    # An explicitly empty value selects external DNS without a lookup.
    if {[info exists ::env(TTREK_HOSTED_ZONE_ID)]} {
        return [zone_id $::env(TTREK_HOSTED_ZONE_ID)]
    }
    set domain [string trimright [string tolower [env_value TTREK_DOMAIN_NAME ttrek.sh]] .]
    set profile [env_value AWS_PROFILE ttrek-prod-neo]
    set region [env_value AWS_REGION [env_value AWS_DEFAULT_REGION eu-central-1]]
    # The CLI handles pagination and emits tab-separated name/ID pairs.
    set zones [exec aws route53 list-hosted-zones \
        --query {HostedZones[?Config.PrivateZone != `true`].[Name,Id]} \
        --output text --no-cli-pager --profile $profile --region $region 2>@stderr]
    set matches {}
    set longest 0
    foreach line [split $zones \n] {
        if {[string trim $line] eq {}} {continue}
        set fields [split $line \t]
        if {[llength $fields] != 2} {error "Unexpected Route 53 hosted-zone response"}
        lassign $fields name id
        set name [string trimright [string tolower $name] .]
        if {$domain ne $name && ![string match "*.$name" $domain]} {continue}
        # Prefer a delegated subdomain zone over its parent.
        set length [string length $name]
        if {$length > $longest} {
            set matches {}
            set longest $length
        }
        if {$length == $longest} {lappend matches $id}
    }
    if {[llength $matches] > 1} {
        error "Multiple matching public hosted zones; set TTREK_HOSTED_ZONE_ID explicitly"
    }
    return [zone_id [lindex $matches 0]]
}

if {[catch {resolve} result options]} {
    puts stderr $result
    if {[lindex [dict get $options -errorcode] 0] eq "CHILDSTATUS"} {
        exit [lindex [dict get $options -errorcode] 2]
    }
    exit 1
}
puts $result
