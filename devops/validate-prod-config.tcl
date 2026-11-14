#
# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.
#

source [file join [file dirname [info script]] .. tcl config.tcl]
if {[llength $argv] != 1} {error "Usage: validate-prod-config.tcl FILE"}
if {[catch {::app_config::validate_lambda_config [lindex $argv 0]}]} {
    puts stderr "Invalid production config: require SSM Redis/PostgreSQL settings and encrypted account keysets/salt; no plaintext secrets"
    exit 1
}
