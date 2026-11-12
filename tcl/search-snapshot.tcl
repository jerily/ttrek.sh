# Shared codec for maintenance publishers and lazy worker caches. Only search
# inputs are snapshotted; display metadata remains in the package tables.
package require tjson
package require ttrie 0.2.0
package require ttrigrams 0.2.0
source [file join [file dirname [info script]] registry-metadata.tcl]
namespace eval ::recipe_search {}

proc ::recipe_search::fold {text} {
    string map {A a B b C c D d E e F f G g H h I i J j K k L l M m N n O o P p Q q R r S s T t U u V v W w X x Y y Z z} $text
}
proc ::recipe_search::valid_name {name} {
    expr {[string length $name] >= 1 && [string length $name] <= 255 &&
          $name ni {. ..} && [regexp {^[A-Za-z0-9._+-]+$} $name]}
}
proc ::recipe_search::snapshot_value {value type} {
    if {[llength $value] != 2 || [lindex $value 0] ne $type} {error "Invalid search snapshot mapping"}
    return [lindex $value 1]
}
proc ::recipe_search::snapshot_builder {} {
    # Bump the first component when normalization, document order or indexing changes.
    return "1/ttrie-[package present ttrie]/ttrigrams-[package present ttrigrams]"
}
proc ::recipe_search::snapshot_digest {bytes} {
    package require twebserver
    binary encode hex [::twebserver::sha256 $bytes]
}

# Canonical search inputs omit URLs and other display-only data. Each distinct
# description/tag maps to a representative version, preserving existing ordering.
proc ::recipe_search::snapshot_inputs {rows} {
    set packages {}
    foreach row $rows {
        set name [dict get $row name]
        set version [dict get $row version]
        if {![valid_name $name] || ![valid_name $version]} continue
        if {[dict exists $packages $name $version]} {error "Duplicate snapshot package version"}
        dict set packages $name $version $row
    }
    set names [lsort -ascii [dict keys $packages]]
    set documents {}
    set texts {}
    foreach name $names {
        set fields [dict create description {} tags {}]
        foreach version [lsort -ascii [dict keys [dict get $packages $name]]] {
            set row [dict get $packages $name $version]
            set text [dict get $row description]
            if {[string length [encoding convertto utf-8 $text]] > 4096 || [string first \u0000 $text] >= 0} {
                error "Invalid snapshot description"
            }
            set tags [::registry_metadata::tags [list L [lmap tag [dict get $row tags] {list S $tag}]] snapshot]
            foreach field {description tags} values [list [expr {$text eq {} ? {} : [list $text]}] $tags] {
                foreach value $values {
                    if {![dict exists $fields $field $value]} {dict set fields $field $value $version}
                }
            }
        }
        foreach field {description tags} {
            foreach text [lsort -ascii [dict keys [dict get $fields $field]]] {
                lappend documents [list L [lmap value [list $name [dict get $fields $field $text] $field] {list S $value}]]
                lappend texts [fold $text]
            }
        }
    }
    set mapping [list M [dict create builder [list S [snapshot_builder]] \
        names [list L [lmap name $names {list S $name}]] documents [list L $documents]]]
    set inputs [::tjson::typed_to_json [list L [list $mapping [list L [lmap text $texts {list S $text}]]]]]
    return [dict create mapping [::tjson::typed_to_json $mapping] names [lmap name $names {fold $name}] \
        texts $texts fingerprint [snapshot_digest [encoding convertto utf-8 $inputs]]]
}

proc ::recipe_search::decode_snapshot_mapping {json} {
    set fields [snapshot_value [::tjson::json_to_typed $json] M]
    if {[lsort [dict keys $fields]] ne {builder documents names} ||
        [snapshot_value [dict get $fields builder] S] ne [snapshot_builder]} {
        error "Unsupported search snapshot mapping"
    }
    set entries {}
    set names {}
    foreach value [snapshot_value [dict get $fields names] L] {
        set name [snapshot_value $value S]
        if {![valid_name $name] || [dict exists $entries $name]} {error "Invalid search snapshot package"}
        dict set entries $name [dict create normalized [fold $name]]
        lappend names $name
    }
    if {$names ne [lsort -ascii $names]} {error "Unordered search snapshot packages"}
    set documents {}
    foreach value [snapshot_value [dict get $fields documents] L] {
        set parts [snapshot_value $value L]
        if {[llength $parts] != 3} {error "Invalid search snapshot document"}
        lassign [lmap part $parts {snapshot_value $part S}] name version field
        if {![dict exists $entries $name] || ![valid_name $version] || $field ni {description tags}} {
            error "Invalid search snapshot document mapping"
        }
        lappend documents [list $name $version $field]
    }
    return [dict create entries $entries documents $documents]
}

proc ::recipe_search::snapshot_revision {snapshot} {
    set parts [list [dict get $snapshot format] [dict get $snapshot fingerprint]]
    lappend parts [snapshot_digest [encoding convertto utf-8 [dict get $snapshot mapping]]]
    foreach field {names descriptions} {lappend parts [snapshot_digest [dict get $snapshot $field]]}
    snapshot_digest [encoding convertto utf-8 $parts]
}
proc ::recipe_search::build_snapshot {inputs} {
    try {
        ::ttrie::create ::recipe_search::build_names [dict get $inputs names]
        ::ttrigrams::create ::recipe_search::build_descriptions [dict get $inputs texts]
        set snapshot [dict create format 3 mapping [dict get $inputs mapping] fingerprint [dict get $inputs fingerprint] \
            names [build_names serialize] descriptions [build_descriptions serialize]]
        dict set snapshot revision [snapshot_revision $snapshot]
        # A publisher must pass the same native loaders and checks as a worker.
        stage_snapshot $snapshot
        return $snapshot
    } finally {
        discard_staged
        foreach command {build_names build_descriptions} {
            if {[llength [info commands ::recipe_search::$command]]} {::recipe_search::$command destroy}
        }
    }
}
proc ::recipe_search::discard_staged {} {
    foreach command {next_names next_descriptions} {
        if {[llength [info commands ::recipe_search::$command]]} {::recipe_search::$command destroy}
    }
}
proc ::recipe_search::stage_snapshot {snapshot} {
    if {[dict get $snapshot format] ne "3"} {error "Unsupported search snapshot format"}
    if {![regexp {^[0-9a-f]{64}$} [dict get $snapshot fingerprint]] ||
        [dict get $snapshot revision] ne [snapshot_revision $snapshot]} {error "Search snapshot checksum mismatch"}
    set data [decode_snapshot_mapping [dict get $snapshot mapping]]
    try {
        ::ttrie::load ::recipe_search::next_names [dict get $snapshot names]
        ::ttrigrams::load ::recipe_search::next_descriptions [dict get $snapshot descriptions]
        if {[next_descriptions count] != [llength [dict get $data documents]]} {error "Search snapshot document count mismatch"}
        dict for {name entry} [dict get $data entries] {
            if {![next_names contains [dict get $entry normalized]]} {error "Search snapshot package is not indexed"}
        }
        return $data
    } on error {message options} {
        discard_staged
        return -options $options $message
    }
}
proc ::recipe_search::load_snapshot {snapshot} {
    set data [stage_snapshot $snapshot]
    try {
        foreach command {index descriptions} {
            if {[llength [info commands ::recipe_search::$command]]} {::recipe_search::$command destroy}
        }
        rename ::recipe_search::next_names ::recipe_search::index
        rename ::recipe_search::next_descriptions ::recipe_search::descriptions
        variable entries [dict get $data entries]
        variable documents [dict get $data documents]
        variable revision [dict get $snapshot revision]
    } finally {discard_staged}
}

# Offline artifacts use base64; database columns retain native binary values.
proc ::recipe_search::snapshot_json {snapshot} {
    set fields [dict create format [list N [dict get $snapshot format]] \
        mapping [::tjson::json_to_typed [dict get $snapshot mapping]]]
    foreach field {revision fingerprint} {dict set fields $field [list S [dict get $snapshot $field]]}
    foreach field {names descriptions} {dict set fields $field [list S [binary encode base64 -maxlen 0 [dict get $snapshot $field]]]}
    ::tjson::typed_to_json [list M $fields]
}
proc ::recipe_search::load {path} {
    if {![file isfile $path]} {error "Search snapshot is missing; run the build-search script"}
    set channel [open $path r]
    try {
        fconfigure $channel -encoding utf-8
        set fields [snapshot_value [::tjson::json_to_typed [read $channel]] M]
    } finally {close $channel}
    set snapshot [dict create format [snapshot_value [dict get $fields format] N] \
        mapping [::tjson::typed_to_json [dict get $fields mapping]]]
    foreach field {revision fingerprint} {dict set snapshot $field [snapshot_value [dict get $fields $field] S]}
    foreach field {names descriptions} {dict set snapshot $field [binary decode base64 -strict [snapshot_value [dict get $fields $field] S]]}
    load_snapshot $snapshot
}
