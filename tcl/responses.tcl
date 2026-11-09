namespace eval ::responses {}

proc ::responses::header {message wanted} {
    set values {}
    if {[dict exists $message headers]} {
        dict for {name value} [dict get $message headers] {
            if {[string equal -nocase $name $wanted]} {lappend values $value}
        }
    }
    if {[dict exists $message multiValueHeaders] && [dict get $message multiValueHeaders] ne "null"} {
        dict for {name items} [dict get $message multiValueHeaders] {
            if {[string equal -nocase $name $wanted]} {set values $items}
        }
    }
    join $values ,
}

proc ::responses::set_header {responseVar name value} {
    upvar 1 $responseVar response
    foreach key [dict keys [dict get $response headers]] {
        if {[string equal -nocase $key $name]} {dict unset response headers $key}
    }
    if {$value ne {}} {dict set response headers $name $value}
}

proc ::responses::accepts_gzip {request} {
    set qualities {}
    foreach item [split [header $request Accept-Encoding] ,] {
        set parts [split $item {;}]
        set coding [string tolower [string trim [lindex $parts 0]]]
        set quality 1
        foreach parameter [lrange $parts 1 end] {
            if {![regexp -nocase {^\s*q\s*=\s*(0(?:\.[0-9]{0,3})?|1(?:\.0{0,3})?)\s*$} $parameter -> quality]} {
                set quality 0
                break
            }
        }
        dict set qualities $coding $quality
    }
    set quality 0
    if {[dict exists $qualities gzip]} {
        set quality [dict get $qualities gzip]
    } elseif {[dict exists $qualities *]} {
        set quality [dict get $qualities *]
    }
    if {[dict exists $qualities identity] && [dict get $qualities identity] > $quality} {return 0}
    expr {$quality > 0}
}

proc ::responses::bytes {response} {
    if {[dict exists $response isBase64Encoded] && [dict get $response isBase64Encoded]} {
        return [binary decode base64 [dict get $response body]]
    }
    encoding convertto utf-8 [dict get $response body]
}

# Choose the wire representation before evaluating validators or suppressing a
# HEAD body. Direct HTTP and Lambda therefore share compression and cache rules.
proc ::responses::prepare {request response} {
    if {[dict get $response statusCode] == 200} {
        set bytes [bytes $response]
        set type [string tolower [string trim [lindex [split [header $response Content-Type] {;}] 0]]]
        if {([string match text/* $type] || $type in {application/javascript application/json image/svg+xml}) &&
            [header $response Content-Encoding] eq {} &&
            ![regexp -nocase {(^|,)\s*no-transform\s*(,|$)} [header $response Cache-Control]]} {
            set vary [header $response Vary]
            if {![regexp -nocase {(^|,)\s*(accept-encoding|\*)\s*(,|$)} $vary]} {
                set_header response Vary [join [concat [expr {$vary eq {} ? {} : [list $vary]}] Accept-Encoding] {, }]
            }
            if {[string length $bytes] >= 1024 && [accepts_gzip $request]} {
                set compressed [zlib gzip $bytes -level 6 -header {time 0}]
                if {[string length $compressed] < [string length $bytes]} {
                    set bytes $compressed
                    dict set response body [binary encode base64 -maxlen 0 $bytes]
                    dict set response isBase64Encoded true
                    set_header response Content-Encoding gzip
                    if {[header $response ETag] ne {}} {
                        set_header response ETag "\"sha256-[::assets::digest $bytes]\""
                    }
                }
            }
        }
        set_header response Content-Length [string length $bytes]
        set etag [header $response ETag]
        if {[dict get $request method] in {GET HEAD} && $etag ne {} &&
            [::assets::matches [header $request If-None-Match] $etag]} {
            dict set response statusCode 304
            dict set response body {}
            set_header response Content-Length {}
        }
    }
    if {[dict get $request method] eq "HEAD"} {dict set response body {}}
    return $response
}
