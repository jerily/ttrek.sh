package require Tcl 9.1
set root [file dirname [file dirname [file normalize [info script]]]]
if {[llength $argv] > 2} {error "Usage: build-search.tcl ?registry_directory? ?output_file?"}
set directory [file join $root registry]
set destination [file join $root search-index.json]
if {[llength $argv] >= 1} {set directory [lindex $argv 0]}
if {[llength $argv] == 2} {set destination [lindex $argv 1]}
source [file join $root tcl search-build.tcl]
puts [::recipe_search::build $directory $destination]
