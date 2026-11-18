#
# Copyright Jerily LTD. All Rights Reserved.
# SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
# SPDX-License-Identifier: MIT.
#

package require twebserver
source [file join [file dirname [info script]] config.tcl]
source [file join [file dirname [info script]] site.tcl]
set settings [::twebserver::get_config_dict]
# Each worker registers routes now and opens SQL on first use, as in Lambda.
try {
    ::site::prepare_worker $settings -secret_config $::site_bootstrap_secrets
} finally {
    unset settings ::site_bootstrap_secrets
}
interp alias {} process_conn {} ::site::process_conn
