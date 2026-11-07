source [file join [file dirname [info script]] .. tcl config.tcl]
if {[llength $argv] != 1} {error "Usage: validate-prod-config.tcl FILE"}
if {[catch {::app_config::validate_lambda_config [lindex $argv 0]}]} {
    puts stderr "Invalid production config: require SSM redis.host and SecureString redis.password; no plaintext secrets"
    exit 1
}
