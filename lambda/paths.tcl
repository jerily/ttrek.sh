# Restrict discovery to this archive, including Tcl's versioned module trees.
set siteRoot [file dirname [file dirname [file normalize [info script]]]]
set auto_path [list $siteRoot [file join $siteRoot local lib] \
    [file join $siteRoot local lib64] [info library]]
foreach directory [::tcl::tm::path list] {::tcl::tm::path remove $directory}
foreach library {lib lib64} {
    foreach directory [glob -nocomplain -types d -directory [file join $siteRoot local $library] tcl8/* tcl9/*] {
        ::tcl::tm::path add $directory
    }
}
encoding system utf-8
