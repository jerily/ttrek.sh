"""Check the Lambda's complete internet route and staged endpoint removal."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
INFRA = ROOT / 'devops/infra'


class CloudFormationLoader(yaml.SafeLoader):
    pass


def intrinsic(loader, tag, node):
    if isinstance(node, yaml.ScalarNode):
        value = loader.construct_scalar(node)
    elif isinstance(node, yaml.SequenceNode):
        value = loader.construct_sequence(node)
    else:
        value = loader.construct_mapping(node)
    return {tag: value}


CloudFormationLoader.add_multi_constructor('!', intrinsic)


def template(path):
    return yaml.load(path.read_text(), Loader=CloudFormationLoader)


class NetworkTests(unittest.TestCase):
    def setUp(self):
        self.base = template(INFRA / '20-infra-vpc0.yml')
        self.resources = self.base['Resources']
        self.function = template(ROOT / 'devops/sam-template.yaml')['Resources']['SiteFunction']

    def imported_resource(self, imported):
        for output in self.base['Outputs'].values():
            export = output['Export']['Name']['Sub'].replace('${AWS::StackName}', 'Infra-DevOps-TTREK-Base')
            if export == imported['ImportValue']:
                return output['Value'].get('Ref', output['Value'].get('GetAtt', '').split('.')[0])
        self.fail(f'Missing export: {imported}')

    def route_table(self, subnet):
        matches = [r['Properties']['RouteTableId']['Ref'] for r in self.resources.values()
                   if r['Type'] == 'AWS::EC2::SubnetRouteTableAssociation'
                   and r['Properties']['SubnetId'] == {'Ref': subnet}]
        self.assertEqual(len(matches), 1)
        return matches[0]

    def internet_route(self, table):
        matches = [r['Properties'] for r in self.resources.values()
                   if r['Type'] == 'AWS::EC2::Route'
                   and r['Properties']['RouteTableId'] == {'Ref': table}
                   and r['Properties'].get('DestinationCidrBlock') == '0.0.0.0/0']
        self.assertEqual(len(matches), 1, f'{table} needs one default route')
        return matches[0]

    def test_every_lambda_subnet_has_a_complete_nat_path(self):
        for imported in self.function['Properties']['VpcConfig']['SubnetIds']:
            subnet = self.imported_resource(imported)
            private = self.resources[subnet]['Properties']
            self.assertFalse(private['MapPublicIpOnLaunch'])
            route = self.internet_route(self.route_table(subnet))
            self.assertNotIn('GatewayId', route)
            nat = self.resources[route['NatGatewayId']['Ref']]
            self.assertEqual(nat['Type'], 'AWS::EC2::NatGateway')
            self.assertNotIn('Condition', nat)
            public_subnet = nat['Properties']['SubnetId']['Ref']
            self.assertNotEqual(subnet, public_subnet)
            public = self.resources[public_subnet]['Properties']
            self.assertEqual(public['AvailabilityZone'], private['AvailabilityZone'])
            self.assertEqual(public['VpcId'], private['VpcId'])
            gateway = self.internet_route(self.route_table(public_subnet))['GatewayId']
            self.assertEqual(self.resources[gateway['Ref']]['Type'], 'AWS::EC2::InternetGateway')
            self.assertTrue(any(r['Type'] == 'AWS::EC2::VPCGatewayAttachment'
                                and r['Properties']['InternetGatewayId'] == gateway
                                and r['Properties']['VpcId'] == private['VpcId']
                                for r in self.resources.values()))
            address = nat['Properties']['AllocationId']['GetAtt'].split('.')[0]
            self.assertEqual(self.resources[address]['Properties']['Domain'], 'vpc')

    def test_lambda_allows_public_https_without_public_ingress(self):
        rds = template(INFRA / '38-infra-rds-postgres.yml')['Resources']
        for imported in self.function['Properties']['VpcConfig']['SecurityGroupIds']:
            group_id = self.imported_resource(imported)
            group = self.resources[group_id]['Properties']
            rules = list(group['SecurityGroupEgress'])
            for resource in rds.values():
                if resource['Type'] == 'AWS::EC2::SecurityGroupEgress':
                    rule = dict(resource['Properties'])
                    if self.imported_resource(rule.pop('GroupId')) == group_id:
                        rules.append(rule)
            public = [rule for rule in rules
                      if rule.get('CidrIp') == '0.0.0.0/0']
            # Duplicate ownership across stacks causes InvalidPermission.Duplicate.
            self.assertEqual(public, [{'IpProtocol': 'tcp', 'FromPort': 443,
                                       'ToPort': 443, 'CidrIp': '0.0.0.0/0'}])
            self.assertFalse(group.get('SecurityGroupIngress'))

    def test_paid_endpoints_are_only_retained_for_migration(self):
        self.assertEqual(self.base['Parameters']['RetainInterfaceEndpoints']['Default'], 'false')
        self.assertEqual(self.base['Conditions']['KeepInterfaceEndpoints'],
                         {'Equals': [{'Ref': 'RetainInterfaceEndpoints'}, 'true']})
        endpoints = [r for r in self.resources.values() if r['Type'] == 'AWS::EC2::VPCEndpoint']
        self.assertEqual(len(endpoints), 4)
        for endpoint in endpoints:
            self.assertEqual(endpoint['Condition'], 'KeepInterfaceEndpoints')
            for group in endpoint['Properties']['SecurityGroupIds']:
                self.assertEqual(self.resources[group['Ref']]['Condition'], 'KeepInterfaceEndpoints')
        # The free S3 route remains in the RDS stack and uses the private table.
        rds = template(INFRA / '38-infra-rds-postgres.yml')['Resources']
        s3 = rds['S3Endpoint']
        self.assertNotIn('Condition', s3)
        self.assertEqual(s3['Properties']['VpcEndpointType'], 'Gateway')
        self.assertEqual(self.imported_resource(s3['Properties']['RouteTableIds'][0]),
                         self.route_table(self.imported_resource(
                             self.function['Properties']['VpcConfig']['SubnetIds'][0])))

    def test_deployment_permissions_fit_and_remain_cloudformation_scoped(self):
        statements = []
        for path in INFRA.glob('00-iam-policy-*.json'):
            policy = json.loads(path.read_text().replace('__REGION__', 'eu-central-1')
                                .replace('__ACCOUNT_ID__', '123456789012'))
            self.assertLessEqual(len(json.dumps(policy, separators=(',', ':'))), 6144, path.name)
            statements.extend(policy['Statement'])
        for action in ('CreateNatGateway', 'DeleteNatGateway', 'AllocateAddress', 'ReleaseAddress',
                       'CreateInternetGateway', 'DeleteInternetGateway', 'AttachInternetGateway',
                       'DetachInternetGateway', 'CreateRoute', 'ReplaceRoute', 'DeleteRoute'):
            grants = [s for s in statements if f'ec2:{action}' in s['Action']]
            self.assertTrue(grants, action)
            for grant in grants:
                self.assertEqual(grant['Condition']['StringEquals']['aws:RequestedRegion'], 'eu-central-1')
                self.assertEqual(grant['Condition']['ForAnyValue:StringEquals']['aws:CalledVia'],
                                 'cloudformation.amazonaws.com')

    def test_launcher_explicitly_selects_endpoint_removal_or_retention(self):
        with tempfile.TemporaryDirectory() as directory:
            aws = Path(directory) / 'aws'
            aws.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
            aws.chmod(0o755)
            env = {**os.environ, 'PATH': f'{directory}:{os.environ["PATH"]}'}
            env.pop('TTREK_RETAIN_INTERFACE_ENDPOINTS', None)
            script = ['bash', str(INFRA / '20-deploy-infra-vpc0.sh')]
            for value in (None, 'true', 'false', 'invalid'):
                with self.subTest(value=value):
                    if value is not None:
                        env['TTREK_RETAIN_INTERFACE_ENDPOINTS'] = value
                    result = subprocess.run(script, env=env, capture_output=True, text=True)
                    if value == 'invalid':
                        self.assertEqual(result.returncode, 2)
                        self.assertEqual(result.stdout, '')
                    else:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertIn(f'RetainInterfaceEndpoints={value or "false"}', result.stdout)


if __name__ == '__main__':
    unittest.main()
