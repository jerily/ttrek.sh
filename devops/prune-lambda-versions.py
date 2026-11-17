#!/usr/bin/env python3
"""Keep the newest five published versions after a successful SAM deployment."""

import argparse
import json
import re
import subprocess


class AwsCli:
    def __init__(self, region=None, profile=None):
        self.options = ['--output', 'json', '--no-cli-pager']
        if region:
            self.options += ['--region', region]
        if profile:
            self.options += ['--profile', profile]

    def __call__(self, *arguments):
        # Leave CLI pagination enabled for versions, aliases and stack resources.
        result = subprocess.run(
            ['aws', *arguments, *self.options], check=True, capture_output=True, text=True,
        )
        return json.loads(result.stdout) if result.stdout.strip() else {}


def completed_stack(aws, stack_name):
    stack = aws('cloudformation', 'describe-stacks', '--stack-name', stack_name)['Stacks'][0]
    if stack['StackStatus'] not in {'CREATE_COMPLETE', 'UPDATE_COMPLETE'}:
        raise ValueError(f"Cleanup requires a successful deployment; stack is {stack['StackStatus']}")
    return stack


def prune(aws, function_name, stack_name, keep=5, dry_run=False):
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', function_name):
        raise ValueError('Use an unqualified Lambda function name')
    if keep < 1:
        raise ValueError('At least one published version must be kept')

    stack = completed_stack(aws, stack_name)
    resources = aws(
        'cloudformation', 'list-stack-resources', '--stack-name', stack_name,
    )['StackResourceSummaries']
    if not any(resource['ResourceType'] == 'AWS::Lambda::Function'
               and resource.get('PhysicalResourceId') == function_name for resource in resources):
        raise ValueError('The specified stack does not own this function')

    protected = set()
    for resource in resources:
        if resource['ResourceType'] == 'AWS::Lambda::Version':
            name, _, version = resource['PhysicalResourceId'].rpartition(':')
            if name.rsplit(':', 1)[-1] == function_name:
                protected.add(version)
    if not protected:
        raise ValueError('The stack has no published version for this function')

    aliases = aws('lambda', 'list-aliases', '--function-name', function_name)['Aliases']
    if not any(alias['Name'] == 'DEFAULT' for alias in aliases):
        raise ValueError('Deploy the DEFAULT alias before cleaning up versions')
    for alias in aliases:
        protected.add(alias['FunctionVersion'])
        protected.update(alias.get('RoutingConfig', {}).get('AdditionalVersionWeights', {}))

    versions = aws(
        'lambda', 'list-versions-by-function', '--function-name', function_name,
    )['Versions']
    published = sorted({item['Version'] for item in versions
                        if re.fullmatch(r'[1-9][0-9]*', item['Version'])}, key=int)
    retained = set(published[-keep:]) | protected
    candidates = [version for version in published if version not in retained]
    print('Keeping published versions: ' + ', '.join(version for version in published if version in retained))
    if not candidates:
        print('No old versions to delete.')
    for version in candidates:
        if dry_run:
            print(f'Would delete {function_name}:{version}')
            continue
        # Stop if another deployment started after we inspected stack ownership.
        if completed_stack(aws, stack_name) != stack:
            raise ValueError('The stack changed during cleanup; retry after deployment completes')
        # Lambda also refuses deletion if an alias has since started using this version.
        # Always supply a numeric qualifier: an unqualified delete removes the function.
        aws('lambda', 'delete-function', '--function-name', function_name, '--qualifier', version)
        print(f'Deleted {function_name}:{version}')
    return candidates


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--function-name', required=True, help='Unqualified function name')
    parser.add_argument('--stack-name', required=True, help='SAM stack owning the function')
    parser.add_argument('--keep', type=int, default=5)
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--region')
    parser.add_argument('--profile')
    args = parser.parse_args()
    try:
        prune(AwsCli(args.region, args.profile), args.function_name, args.stack_name,
              args.keep, args.dry_run)
    except subprocess.CalledProcessError as error:
        parser.exit(1, f'AWS cleanup failed: {error.stderr.strip()}\n')
    except ValueError as error:
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    main()
