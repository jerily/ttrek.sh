# Build-time input only. Each package gets a fresh checkout of the public
# registry's default branch; the deployed sync task imports it into the database.
namespace eval ::registry_build {}
proc ::registry_build::git {args} {exec git {*}$args}
proc ::registry_build::stage {root} {
    set directory [file join $root registry]
    if {[file exists $directory]} {error "Registry staging directory already exists: $directory"}
    try {
        git clone --quiet --depth 1 --single-branch --no-tags -- \
            https://github.com/jerily/ttrek-registry.git $directory
        if {![llength [glob -nocomplain -directory $directory -types f */*/ttrek.json]]} {
            error "The fetched registry contains no recipes"
        }
        set revision [string trim [git -C $directory rev-parse HEAD]]
        if {![regexp {^[0-9a-f]{40,64}$} $revision]} {error "Invalid registry Git revision"}
        file delete -force [file join $directory .git]
        file mkdir [file join $root etc]
        set channel [open [file join $root etc registry-revision] w]
        try {puts $channel $revision} finally {close $channel}
        puts "Bundled jerily/ttrek-registry at $revision"
        return $revision
    } on error {message options} {
        file delete -force $directory
        return -options $options $message
    }
}
