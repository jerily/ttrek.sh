# Editorial configuration is loaded once per worker. Published metadata is read
# on each homepage request so syncs reach warm workers without invalidation.
namespace eval ::homepage {
    variable config {autoplay false slides {}}
}

proc ::homepage::configure {root} {
    variable config
    set config {autoplay false slides {}}
    if {[catch {
        set json [encoding convertfrom utf-8 [::assets::read_bytes [file join $root etc homepage.json]]]
        set node [::tjson::json_to_typed $json]
        if {[lindex $node 0] ne "M"} {error "expected an object"}
        set fields [lindex $node 1]
        if {[dict get $fields version] ne {N 1} ||
            [lindex [dict get $fields slides] 0] ne "L" ||
            [lindex [dict get $fields autoplay] 0] ne "BOOL"} {
            error "expected version 1, slides array and autoplay boolean"
        }
        set config [::tjson::json_to_simple $json]
    } message]} {
        puts stderr "Homepage showcase disabled: $message"
    }
}

proc ::homepage::text_fields {values} {
    set result {}
    dict for {key value} $values {dict set result $key [list S $value]}
    return $result
}

proc ::homepage::stores {} {
    set settings [::site::config]
    if {![dict exists $settings content_connection]} {return {}}
    set images {}
    if {[dict exists $settings content_images]} {set images [dict get $settings content_images]}
    ::content_images::database_stores [dict get $settings content_connection] $images
}

# Reuse the content package's published image references and URL resolver.
# Signed URLs are generated for this response, never kept in a metadata cache.
proc ::homepage::image {entry store item} {
    set source [dict get $entry image]
    lassign [::web::static::wiki::image_source $source] normalized fragment
    if {$normalized ne $source || $fragment ne {}} {error "invalid showcase image"}
    foreach key {image_width image_height} {
        if {![string is integer -strict [dict get $entry $key]] || [dict get $entry $key] < 1} {
            error "invalid image dimensions"
        }
    }
    set image [dict create src /homepage/images/[dict get $entry id] \
        alt [dict get $entry image_alt] width [dict get $entry image_width] height [dict get $entry image_height]]
    if {[dict get $store -s3] ne {}} {
        set reference [dict get $item image_references $source]
        dict set image src $source
    } else {
        set filename [file join [::site::root] content docs $source]
        if {![file isfile $filename] || [::web::static::wiki::image_type $filename] eq {}} {
            error "showcase image is unavailable: $source"
        }
    }
    set markup [::jinja2::render {<img src="{{ src }}" alt="{{ alt }}" width="{{ width }}" height="{{ height }}" decoding="async" loading="lazy">} \
        [::tjson::typed_to_json [list M [text_fields $image]]]]
    if {[dict get $store -s3] ne {}} {
        # Let the package validate/sign the URL; only this generated img is HTML.
        return [::web::static::wiki::render_markdown $store [dict create \
            markdown_html $markup image_references [dict create $source $reference]]]
    }
    return $markup
}

proc ::homepage::resolve {entries stores} {
    set slides {}
    set seen {}
    set pages {}
    set posts {}
    set items {}
    # Either collection may be unavailable independently during provisioning.
    catch {
        foreach page [::web::static::wiki::children [dict get $stores wiki] /] {
            if {[dict get $page item_type] eq "page"} {dict set pages [dict get $page path] $page}
        }
    }
    catch {set posts [::web::static::blog::posts [dict get $stores blog]]}
    foreach entry $entries {
        try {
            set id [dict get $entry id]
            if {![regexp {^[a-z][a-z0-9-]*$} $id] || $id in $seen} {continue}
            set type [dict get $entry type]
            set fields [text_fields [dict create id $id type $type \
                label [dict get $entry label] kicker [dict get $entry kicker] \
                link_text [dict get $entry link_text]]]
            switch -- $type {
                example - doc {
                    set path [dict get $entry path]
                    if {![dict exists $pages $path]} {continue}
                    foreach key {title description} {dict set fields $key [list S [dict get $entry $key]]}
                    dict set fields url [list S /docs$path]
                    if {$type eq "example"} {
                        if {![dict exists $items $path]} {
                            dict set items $path [::web::static::wiki::load [dict get $stores wiki] $path]
                        }
                        dict set fields image_html [list S [image $entry [dict get $stores wiki] [dict get $items $path]]]
                        dict set fields preview_label [list S [dict get $entry preview_label]]
                    } else {
                        dict set fields commands [list S [dict get $entry commands]]
                    }
                }
                latest_blog {
                    if {![llength $posts]} {continue}
                    set post [lindex $posts 0]
                    set path [dict get $post path]
                    ::web::static::blog::canonical_path $path
                    dict set fields title [list S [dict get $post title]]
                    dict set fields date [list S [dict get $post published_at]]
                    dict set fields url [list S /blog$path]
                    dict set fields description {S {Release notes, practical guides, and news from ttrek.}}
                    dict set fields note {S {Ideas for your next Tcl project.}}
                    dict set fields version {S {}}
                    if {[dict exists $entry highlights $path]} {
                        foreach key {description version note} {
                            dict set fields $key [list S [dict get $entry highlights $path $key]]
                        }
                    }
                }
                packages {
                    set names [lrange [dict get $entry packages] 0 2]
                    if {![llength $names]} {continue}
                    set catalog [::recipe_search::catalog_entries [::recipe_search::database registry_catalog $names]]
                    set cards {}
                    foreach name $names {
                        if {![dict exists $catalog $name]} {continue}
                        lappend cards [list M [text_fields [dict create name $name \
                            description [dict get $catalog $name description] url /package/$name]]]
                    }
                    if {![llength $cards]} {continue}
                    foreach key {title description} {dict set fields $key [list S [dict get $entry $key]]}
                    dict set fields url {S /packages}
                    dict set fields packages [list L $cards]
                }
                default {continue}
            }
            lappend slides [list M $fields]
            lappend seen $id
        } on error {message options} {
            puts stderr "Skipping unavailable homepage entry: $message"
        }
        if {[llength $slides] == 5} {break}
    }
    return [list L $slides]
}

proc ::homepage::data {} {
    variable config
    set stores {}
    catch {set stores [stores]}
    dict create slides [resolve [dict get $config slides] $stores] \
        autoplay [list BOOL [dict get $config autoplay]]
}

# With image storage disabled, serve only images explicitly selected in the
# trusted configuration. No request-supplied path is used to read a file.
proc get_homepage_image_handler {ctx req} {
    set id [::twebserver::get_path_param $req id]
    foreach entry [dict get $::homepage::config slides] {
        if {[dict get $entry id] ne $id || [dict get $entry type] ne "example"} {continue}
        set source [dict get $entry image]
        lassign [::web::static::wiki::image_source $source] normalized fragment
        if {$normalized ne $source || $fragment ne {}} {break}
        set filename [file join [::site::root] content docs $source]
        set type [::web::static::wiki::image_type $filename]
        if {$type eq {} || ![file isfile $filename]} {break}
        return [::assets::respond /homepage/images/$id $req $type [::assets::read_bytes $filename]]
    }
    return [::assets::unavailable]
}
