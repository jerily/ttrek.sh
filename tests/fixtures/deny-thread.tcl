# Fail even a transitive attempt to load Thread in the website interpreter.
namespace eval ::without_thread {}
rename ::package ::without_thread::package
proc ::package {subcommand args} {
    if {$subcommand eq "require" && [string equal -nocase [lindex $args 0] -exact]} {
        set name [lindex $args 1]
    } else {set name [lindex $args 0]}
    if {$subcommand eq "require" && [string equal -nocase $name thread]} {
        error "The website must run without the Thread package"
    }
    uplevel 1 [list ::without_thread::package $subcommand {*}$args]
}
