# Version 1 fixture writer for compatibility tests only.
# Serialize one record into the maintenance backup.
proc ::legacy_backup::write_record {channel record} {
    puts $channel [::tjson::typed_to_json [list M $record]]
}

# A repeatable-read snapshot includes all dimensions and events consistently.
# Server-side cursors bound memory even when an event table grows large.
proc ::legacy_backup::backup {db path deadline} {
    set channel [open $path wb]
    zlib push gzip $channel
    fconfigure $channel -encoding utf-8 -translation lf
    set definitions [::telemetry::table_definitions]
    set tables {}
    foreach table [dict keys $definitions] {lappend tables [list S $table]}
    set counts {}
    try {
        $db allrows {BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY}
        write_record $channel [dict create format {S ttrek-telemetry} version {N 1} \
            created_at [list N [clock seconds]] tables [list L $tables]]
        dict for {table definition} $definitions {
            set count 0
            set query [::tpersist::db_compile [::tpersist::db_select $table] -dialect postgresql]
            $db allrows "DECLARE telemetry_export NO SCROLL CURSOR FOR [dict get $query sql]"
            while {1} {
                ::telemetry_maintenance::check_deadline $deadline
                set timeout [expr {max(1, min(20000, $deadline - [clock milliseconds]))}]
                $db allrows "SET LOCAL statement_timeout = $timeout"
                set rows [$db allrows {FETCH FORWARD 256 FROM telemetry_export}]
                if {![llength $rows]} break
                foreach row $rows {
                    set values {}
                    dict for {column spec} [dict get $definition columns] {
                        set value [dict get $row $column]
                        switch -- [dict get $spec type] {
                            binary {set value [list S [binary encode base64 -maxlen 0 $value]]}
                            text {set value [list S $value]}
                            default {set value [list N $value]}
                        }
                        dict set values $column $value
                    }
                    write_record $channel [dict create table [list S $table] values [list M $values]]
                    incr count
                }
                # Leave room for the runtime in Lambda's default 512 MiB /tmp.
                flush $channel
                if {[file size $path] > 400 * 1024 * 1024} {error "Telemetry backup exceeds 400 MiB"}
            }
            $db allrows {CLOSE telemetry_export}
            dict set counts $table [list N $count]
        }
        $db allrows COMMIT
        write_record $channel [dict create complete {BOOL 1} counts [list M $counts]]
    } on error {message options} {
        catch {$db allrows ROLLBACK}
        return -options $options $message
    } finally {close $channel}
}
