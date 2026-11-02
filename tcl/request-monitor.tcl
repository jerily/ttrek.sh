namespace eval ::request_monitor {}

proc ::request_monitor::context {} {
    return [::treqmon::view::context [::treqmon::get_history_events] \
        [expr {![catch {package present tsession}]}]]
}
