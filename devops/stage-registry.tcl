# Build-time input only. CodeBuild supplies its synced public checkout; local
# packaging can fetch one. The deployed sync task imports the bundled snapshot.
namespace eval ::registry_build {}
proc ::registry_build::git {args} {exec git {*}$args}
proc ::registry_build::stage {root {source {}}} {
    set directory [file join $root registry]
    if {[file exists $directory]} {error "Registry staging directory already exists: $directory"}
    try {
        if {$source eq {}} {
            git clone --quiet --depth 1 --single-branch --no-tags -- \
                https://github.com/jerily/ttrek-registry.git $directory
            set revision [string trim [git -C $directory rev-parse HEAD]]
            file delete -force [file join $directory .git]
        } else {
            if {![file isdirectory $source] || ![file exists [file join $source .git]]} {
                error "Public registry checkout does not exist: $source"
            }
            if {[git -C $source status --porcelain] ne {}} {
                error "Public registry checkout has local changes: $source"
            }
            set revision [string trim [git -C $source rev-parse HEAD]]
            file mkdir $directory
            # Archive the recorded commit, excluding Git metadata and ignored
            # files without modifying or fetching the dependency checkout.
            git -C $source archive --format=tar $revision | tar -xf - -C $directory
        }
        if {![llength [glob -nocomplain -directory $directory -types f */*/ttrek.json]]} {
            error "The public registry contains no recipes"
        }
        if {![regexp {^[0-9a-f]{40,64}$} $revision]} {error "Invalid registry Git revision"}
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
