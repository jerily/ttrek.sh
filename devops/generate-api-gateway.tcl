# Website policy for the tdevops generate-api-gateway script.
namespace eval ::site_gateway {}

# Keep JSON types while normalizing only production routes.
proc ::site_gateway::production_routes {definitions} {
    set routes {}
    foreach typed $definitions {
        lassign $typed type route
        if {$type ne "M"} {error "each route must be an object"}
        if {[dict exists $route cdn_on_prod]} {
            lassign [dict get $route cdn_on_prod] type cdn
            if {$type ne "BOOL"} {error "cdn_on_prod must be a boolean"}
            if {$cdn} {continue}
            dict unset route cdn_on_prod
        }
        lassign [dict get $route path] type path
        if {$type ne "S" || ![string match /* $path] || [string first // $path] >= 0} {
            error "Invalid API Gateway route path: $path"
        }
        set path [string trimright $path /]
        if {$path eq {}} {set path /}
        if {$path eq "/debug"} {continue}
        dict set route path [list S $path]
        if {![dict exists $route method]} {dict set route method {S ANY}}
        set key "[lindex [dict get $route method] 1] $path"
        if {[dict exists $routes $key]} {
            set previous [dict get $routes $key]
            set same [expr {[lsort [dict keys $previous]] eq [lsort [dict keys $route]]}]
            dict for {name value} $route {
                if {![dict exists $previous $name] || [dict get $previous $name] ne $value} {set same 0}
            }
            if {!$same} {error "Conflicting API Gateway routes after normalization: $key"}
        }
        dict set routes $key $route
    }
    return [lmap route [dict values $routes] {list M $route}]
}

proc ::site_gateway::route_logical_id {key} {
    if {$key eq "GET /"} {return RootRoute}
    set separator [string first " " $key]
    set result [string totitle [string range $key 0 $separator-1]]
    set path [string range $key $separator+1 end]
    foreach segment [split [string trim $path /] /] {
        if {[string index $segment 0] eq "\{"} {append result By}
        foreach word [regexp -all -inline {[A-Za-z0-9]+} $segment] {
            append result [string toupper [string index $word 0]][string range $word 1 end]
        }
    }
    if {$path eq "/"} {append result Root}
    return ${result}Route
}

proc ::site_gateway::rename {typed names} {
    lassign $typed type value
    switch -- $type {
        M {
            set result {}
            dict for {key item} $value {
                if {[dict exists $names $key]} {set key [dict get $names $key]}
                dict set result $key [rename $item $names]
            }
            set value $result
        }
        L {set value [lmap item $value {rename $item $names}]}
        S {
            if {[dict exists $names $value]} {set value [dict get $names $value]}
            set replacements {}
            dict for {old new} $names {lappend replacements \$\{$old\} \$\{$new\}}
            set value [string map $replacements $value]
        }
    }
    return [list $type $value]
}

proc ::site_gateway::customize {json maintained} {
    lassign [::tjson::json_to_typed $json] type document
    foreach section {Parameters Conditions Resources} {set $section [lindex [dict get $document $section] 1]}
    dict unset Parameters AuthorizerFunction
    dict unset Conditions AuthorizerFunctionIsArn
    dict unset Conditions UseAuthorizer
    dict unset Resources LambdaAuthorizer
    dict unset Resources AuthorizerPermission
    set functions [dict keys $Parameters Function*]
    if {[llength $functions] != 1} {error "Expected one website Lambda function"}
    set function [lindex $functions 0]
    set names [dict create $function LambdaFunctionName ${function}IsArn LambdaFunctionIsArn]
    set routeNames {}
    dict for {name typed} $Resources {
        set resource [lindex $typed 1]
        switch -- [lindex [dict get $resource Type] 1] {
            AWS::ApiGatewayV2::Integration {dict set names $name SiteIntegration}
            AWS::Lambda::Permission {dict set names $name SitePermission}
            AWS::ApiGatewayV2::Route {
                set properties [lindex [dict get $resource Properties] 1]
                dict set properties AuthorizationType {S NONE}
                dict unset properties AuthorizerId
                set logical [route_logical_id [lindex [dict get $properties RouteKey] 1]]
                if {$logical in $routeNames} {error "Duplicate route logical ID: $logical"}
                lappend routeNames $logical
                dict set names $name $logical
                dict set resource Properties [list M $properties]
                dict set Resources $name [list M $resource]
            }
        }
    }
    foreach section {Parameters Conditions Resources} {dict set document $section [list M [set $section]]}
    set document [lindex [rename [list M $document] $names] 1]
    foreach {section keys} {
        Parameters {DomainName CertificateStackName CertificateArn HostedZoneId}
        Conditions {UseRoute53 UseExistingCertificate}
        Resources {SiteDomain SiteMapping SiteDns}
        Outputs {SiteUrl RegionalDomainName RegionalHostedZoneId}
    } {
        set fields [lindex [dict get $document $section] 1]
        set preserved [lindex [dict get $maintained $section] 1]
        foreach key $keys {dict set fields $key [dict get $preserved $key]}
        dict set document $section [list M $fields]
    }
    set resources [lindex [dict get $document Resources] 1]
    set integration [lindex [dict get $resources SiteIntegration] 1]
    dict set integration DependsOn {S SitePermission}
    dict set resources SiteIntegration [list M $integration]
    dict set document Resources [list M $resources]
    set parameters [lindex [dict get $document Parameters] 1]
    set function [lindex [dict get $parameters LambdaFunctionName] 1]
    dict set function Description {S {Existing website Lambda name or ARN}}
    dict set parameters LambdaFunctionName [list M $function]
    dict set document Parameters [list M $parameters]
    dict set document Description [dict get $maintained Description]
    ::tjson::create [list M $document] template
    return [::tjson::to_pretty_json $template]
}

proc ::site_gateway::main {options} {
    package require tjson
    set root $::tdevops::root
    set destination [file join $root devops infra 40-api-gateway.json]
    set maintained [lindex [::tjson::json_to_typed [::tdevops::read_text $destination]] 1]
    set input [dict get $options --routes]
    set output [dict get $options --output]
    if {$input eq $destination || $input eq $output} {error "output must not overwrite the routes configuration"}
    lassign [::tjson::json_to_typed [::tdevops::read_text $input]] type routes
    if {$type ne "M"} {error "configuration must be a JSON object"}
    if {[dict exists $routes apiGateway] && [dict exists [lindex [dict get $routes apiGateway] 1] authorizer]} {
        error "The website is public; remove apiGateway.authorizer"
    }
    lassign [dict get $routes routes] type definitions
    if {$type ne "L"} {error "routes must be an array"}
    dict set routes routes [list L [production_routes $definitions]]
    set channel [file tempfile temporary]
    try {
        fconfigure $channel -encoding utf-8 -translation lf
        puts $channel [::tjson::typed_to_json [list M $routes]]
        close $channel
        set channel {}
        set json [customize [::tdevops::apigateway::render $temporary] $maintained]
    } finally {
        if {$channel ne {}} {close $channel}
        file delete -force $temporary
    }
    ::tdevops::apigateway::write $output $json
    if {$output eq [file join $root dist api-gateway.json]} {
        ::tdevops::apigateway::write $destination $json
    }
}
