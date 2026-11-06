# Shared by the direct HTTP server and the Lambda HTTP-event adapter.
return {
    GET /request-monitor get_stats_handler get_stats
    GET /debug get_debug_handler get_debug
    GET / get_index_page_handler get_index
    GET /init get_ttrek_init_handler get_ttrek_init
    GET /packages get_packages_page_handler get_packages
    GET /:type(css|js|assets)/:path(.*) get_assets_handler get_assets
    GET /dist/:arch/ttrek:ext? get_dist_handler get_dist
    GET /releases/latest/:target get_release_handler get_release
    GET /package/:package_name get_package_page_handler get_package
    GET /package/:package_name/:package_version get_package_version_page_handler get_package_version
    GET /registry/:package_name/:package_version/:os/:machine get_package_spec_handler get_package_spec
    GET /registry/search get_search_handler get_search
    GET /registry/:package_name get_package_versions_handler get_package_versions
    POST /telemetry/register/:environment_id post_telemetry_register_handler post_telemetry_register
    POST /telemetry/collect/:package_name/:package_version post_telemetry_collect_handler post_telemetry_collect
    GET /logo get_logo_handler get_logo
    GET /:path(.*) get_catchall_handler get_catchall
}
