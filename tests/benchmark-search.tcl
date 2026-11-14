# Reproducible local benchmark; all database writes use an in-memory fixture.
set root [file dirname [file dirname [file normalize [info script]]]]
source [file join $root tcl telemetry.tcl]
source [file join $root tcl search.tcl]
::telemetry::init_local {dialect sqlite database :memory:} [list [file join [file dirname $root] ttrek-registry]]
set rows [::telemetry::registry_catalog]
set inputs [::recipe_search::snapshot_inputs $rows]
set snapshot [::telemetry::search_snapshot]
set iterations 50
proc build_native {} {
    ::ttrie::create bench_names [dict get $::inputs names]
    ::ttrigrams::create bench_descriptions [dict get $::inputs texts]
    bench_names destroy
    bench_descriptions destroy
}
proc load_native {} {
    ::ttrie::load bench_names [dict get $::snapshot names]
    ::ttrigrams::load bench_descriptions [dict get $::snapshot descriptions]
    bench_names destroy
    bench_descriptions destroy
}
set sizes {}
foreach field {mapping names descriptions} {
    set bytes [dict get $snapshot $field]
    if {$field eq "mapping"} {set bytes [encoding convertto utf-8 $bytes]}
    dict set sizes $field [string length $bytes]
}
set build_us [lindex [time build_native $iterations] 0]
set load_us [lindex [time load_native $iterations] 0]
set publish_us [lindex [time {::recipe_search::build_snapshot [::recipe_search::snapshot_inputs $rows]} $iterations] 0]
set worker_us [lindex [time {::recipe_search::load_snapshot $snapshot} $iterations] 0]
puts [dict create packages [llength [dict get $inputs names]] versions [llength $rows] \
    documents [llength [dict get $inputs texts]] bytes $sizes iterations $iterations \
    native_build_us $build_us native_load_us $load_us publication_build_us $publish_us validated_worker_load_us $worker_us]
::telemetry::close
