# The forum borrows this worker's account store, connection and site layout.
namespace eval ::site_forum {}
proc ::site_forum::mount {router settings templates args} {
    package require web-forum 0.3.4
    set config {}
    if {[dict exists $settings forum]} {set config [dict get $settings forum]}
    dict set config validate_templates [::site::validate_templates]
    dict set config master_template [dict get $templates forum-master.html.jinja]
    dict set config templates [dict create master.html.jinja [dict get $templates master.html.jinja]]
    dict set config assets_url [::assets::base_url /forum/_assets]
    dict set config widgets profile [list ::web::user::widget $::accounts::mount profile]
    ::web::forum::mount $router -store $::accounts::store -user $::accounts::mount -config $config {*}$args
}

proc ::site_forum::prepare {settings} {
    package require web-forum 0.3.4
    set config {}
    if {[dict exists $settings forum]} {set config [dict get $settings forum]}
    set config [dict merge $config [::views::mount_settings forum]]
    dict set config assets_url [::assets::base_url /forum/_assets]
    dict set config widgets profile [list ::web::user::widget $::accounts::mount profile]
    ::web::forum::prepare_mount -store $::accounts::store -user $::accounts::mount -config $config
}
