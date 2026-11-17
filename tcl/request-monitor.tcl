# Render the bounded request log. The shared monitor middleware checks access
# before this handler can read any request metadata.
proc get_recent_requests_handler {context request} {
    set requests {}
    if {[dict exists [::site::config] treqmon]} {set requests [::treqmon::get_recent_requests]}
    set rows {}
    foreach entry $requests {
        set fields {}
        foreach key {ip method path status user_agent} {
            set value [dict get $entry $key]
            if {$value eq {}} {set value —}
            dict set fields $key [list S $value]
        }
        dict set fields time [list S [clock format [dict get $entry timestamp] -gmt true -format {%Y-%m-%d %H:%M:%S}]]
        lappend rows [list M $fields]
    }
    set html [::views::render request-monitor-recent.html.jinja [dict create \
        title {S {Last 100 requests}} requests [list L $rows] count [list N [llength $rows]]]]
    set response [::twebserver::build_response 200 text/html $html]
    dict set response headers Cache-Control no-store
    return $response
}
