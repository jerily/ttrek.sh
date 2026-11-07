#!/usr/bin/env python3
"""Regenerate the public website API and preserve its domain configuration."""

import json
from pathlib import Path
import subprocess


def main():
    root = Path(__file__).resolve().parent.parent
    destination = root / 'devops/infra/40-api-gateway.json'
    maintained = json.loads(destination.read_text())
    routes = json.loads((root / 'etc/routes.json').read_text())
    if 'authorizer' in routes.get('apiGateway', {}):
        raise ValueError('The website is public; remove apiGateway.authorizer')

    subprocess.run(
        ['ttrek', 'run', '-package', 'tdevops', '-script', 'generate-api-gateway'],
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
    route_names = {'ANY /': 'RootRoute', 'ANY /{proxy+}': 'ProxyRoute'}
    for name, resource in template['Resources'].items():
        if resource['Type'] == 'AWS::ApiGatewayV2::Integration':
            names[name] = 'SiteIntegration'
        elif resource['Type'] == 'AWS::Lambda::Permission':
            names[name] = 'SitePermission'
        elif resource['Type'] == 'AWS::ApiGatewayV2::Route':
            properties = resource['Properties']
            properties['AuthorizationType'] = 'NONE'
            properties.pop('AuthorizerId', None)
            if properties['RouteKey'] in route_names:
                names[name] = route_names[properties['RouteKey']]

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
