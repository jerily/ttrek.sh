# The forum borrows this worker's account store, connection and site layout.
namespace eval ::site_forum {}
proc ::site_forum::mount {router settings templates} {
    package require web-forum 0.3.0
    set config {}
    if {[dict exists $settings forum]} {set config [dict get $settings forum]}
    dict set config master_template [dict get $templates forum-master.html.jinja]
    dict set config templates [dict create master.html.jinja [dict get $templates master.html.jinja]]
    dict set config widgets profile [list ::web::user::widget $::accounts::mount profile]
    ::web::forum::mount $router -store $::accounts::store -user $::accounts::mount -config $config
}
