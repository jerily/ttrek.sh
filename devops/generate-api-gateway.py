#!/usr/bin/env python3
"""Regenerate the public website API and preserve its domain configuration."""

import json
from pathlib import Path
import re
import subprocess
import tempfile


def production_routes(definitions):
    routes = {}
    for definition in definitions:
        cdn = definition.get('cdn_on_prod', False)
        if type(cdn) is not bool:
            raise ValueError('cdn_on_prod must be a boolean')
        if cdn:
            continue
        route = dict(definition)
        route.pop('cdn_on_prod', None)
        path = route['path']
        if not isinstance(path, str) or not path.startswith('/') or '//' in path:
            raise ValueError(f'Invalid API Gateway route path: {path!r}')
        # Local routes may include /docs/ aliases; Gateway rejects the empty segment.
        route['path'] = path.rstrip('/') or '/'
        route['method'] = route.get('method', 'ANY')
        key = f"{route['method']} {route['path']}"
        if key in routes and routes[key] != route:
            raise ValueError(f'Conflicting API Gateway routes after normalization: {key}')
        routes[key] = route
    return list(routes.values())


def route_logical_id(route_key):
    method, path = route_key.split(' ', 1)
    if route_key == 'GET /':
        return 'RootRoute'
    parts = [method.title()]
    for segment in path.strip('/').split('/'):
        if segment.startswith('{'):
            parts.append('By')
        parts.extend(word[0].upper() + word[1:] for word in re.findall(r'[A-Za-z0-9]+', segment))
    if path == '/':
        parts.append('Root')
    return ''.join(parts) + 'Route'


def main():
    root = Path(__file__).resolve().parent.parent
    destination = root / 'devops/infra/40-api-gateway.json'
    maintained = json.loads(destination.read_text())
    routes = json.loads((root / 'etc/routes.json').read_text())
    if 'authorizer' in routes.get('apiGateway', {}):
        raise ValueError('The website is public; remove apiGateway.authorizer')

    routes['routes'] = production_routes(routes['routes'])
    with tempfile.NamedTemporaryFile(mode='w', suffix='.json') as filtered:
        json.dump(routes, filtered)
        filtered.flush()
        subprocess.run(
            ['ttrek', 'run', '-package', 'tdevops', '-script', 'generate-api-gateway',
             '--', '--routes', filtered.name],
            cwd=root, check=True,
        )
    generated = root / 'dist/api-gateway.json'
    template = json.loads(generated.read_text())
    del template['Parameters']['AuthorizerFunction']
    del template['Conditions']['AuthorizerFunctionIsArn']
    del template['Conditions']['UseAuthorizer']
    del template['Resources']['LambdaAuthorizer']
    del template['Resources']['AuthorizerPermission']

    # Preserve deployed logical IDs so regeneration does not replace integrations/routes.
    functions = [name for name in template['Parameters'] if name.startswith('Function')]
    if len(functions) != 1:
        raise ValueError('Expected one website Lambda function')
    function = functions[0]
    names = {
        function: 'LambdaFunctionName',
        function + 'IsArn': 'LambdaFunctionIsArn',
    }
    route_names = set()
    for name, resource in template['Resources'].items():
        if resource['Type'] == 'AWS::ApiGatewayV2::Integration':
            names[name] = 'SiteIntegration'
        elif resource['Type'] == 'AWS::Lambda::Permission':
            names[name] = 'SitePermission'
        elif resource['Type'] == 'AWS::ApiGatewayV2::Route':
            properties = resource['Properties']
            properties['AuthorizationType'] = 'NONE'
            properties.pop('AuthorizerId', None)
            logical_id = route_logical_id(properties['RouteKey'])
            if logical_id in route_names:
                raise ValueError(f'Duplicate route logical ID: {logical_id}')
            route_names.add(logical_id)
            names[name] = logical_id

    def rename(value):
        if isinstance(value, dict):
            return {names.get(key, key): rename(item) for key, item in value.items()}
        if isinstance(value, list):
            return [rename(item) for item in value]
        if isinstance(value, str):
            value = names.get(value, value)
            for old, new in names.items():
                value = value.replace('${' + old + '}', '${' + new + '}')
        return value

    template = rename(template)
    # Create the alias invocation permission before switching the live integration.
    template['Resources']['SiteIntegration']['DependsOn'] = 'SitePermission'
    template['Description'] = maintained['Description']
    template['Parameters']['LambdaFunctionName']['Description'] = 'Existing website Lambda name or ARN'
    # These deployment settings are maintained in the tracked template, not tdevops.
    for section, keys in {
        'Parameters': ['DomainName', 'CertificateStackName', 'CertificateArn', 'HostedZoneId'],
        'Conditions': ['UseRoute53', 'UseExistingCertificate'],
        'Resources': ['SiteDomain', 'SiteMapping', 'SiteDns'],
        'Outputs': ['SiteUrl', 'RegionalDomainName', 'RegionalHostedZoneId'],
    }.items():
        for key in keys:
            template[section][key] = maintained[section][key]

    text = json.dumps(template, indent=2) + '\n'
    generated.write_text(text)
    destination.write_text(text)
    print(f'Created {destination}')


if __name__ == '__main__':
    main()
