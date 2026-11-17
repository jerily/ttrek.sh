"""Exercise version cleanup and deployment arguments without contacting AWS."""

import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location('prune_versions', ROOT / 'devops/prune-lambda-versions.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
FUNCTION = 'website'
STACK = 'website-stack'


class FakeAws:
    def __init__(self):
        self.calls = []
        self.status = 'UPDATE_COMPLETE'
        self.change_status = False
        self.fail = None
        self.resources = [
            {'ResourceType': 'AWS::Lambda::Function', 'PhysicalResourceId': FUNCTION},
            {'ResourceType': 'AWS::Lambda::Version',
             'PhysicalResourceId': f'arn:aws:lambda:eu-central-1:123456789012:function:{FUNCTION}:12'},
        ]
        self.aliases = [{'Name': 'DEFAULT', 'FunctionVersion': '12'}]
        self.versions = [{'Version': '$LATEST'}] + [{'Version': str(n)} for n in range(1, 13)]

    def __call__(self, *args):
        self.calls.append(args)
        operation = args[1]
        if operation == self.fail:
            raise subprocess.CalledProcessError(1, args, stderr='AWS request failed')
        if operation == 'describe-stacks':
            status = self.status
            if self.change_status:
                self.status = 'UPDATE_IN_PROGRESS'
            return {'Stacks': [{'StackStatus': status, 'StackId': STACK}]}
        if operation == 'list-stack-resources':
            return {'StackResourceSummaries': copy.deepcopy(self.resources)}
        if operation == 'list-aliases':
            return {'Aliases': copy.deepcopy(self.aliases)}
        if operation == 'list-versions-by-function':
            return {'Versions': copy.deepcopy(self.versions)}
        if operation == 'delete-function':
            return {}
        raise AssertionError(args)

    @property
    def deletes(self):
        return [call for call in self.calls if call[1] == 'delete-function']


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.aws = FakeAws()
        self.output = contextlib.redirect_stdout(io.StringIO())
        self.output.__enter__()
        self.addCleanup(self.output.__exit__, None, None, None)

    def run_prune(self, **kwargs):
        return MODULE.prune(self.aws, FUNCTION, STACK, **kwargs)

    def test_keeps_newest_five_in_numeric_order_and_only_deletes_qualified_versions(self):
        self.assertEqual(self.run_prune(), [str(n) for n in range(1, 8)])
        self.assertEqual(self.aws.deletes, [
            ('lambda', 'delete-function', '--function-name', FUNCTION, '--qualifier', str(n))
            for n in range(1, 8)
        ])

    def test_preserves_aliases_weighted_targets_and_versions_owned_by_stack(self):
        self.aws.aliases += [
            {'Name': 'rollback', 'FunctionVersion': '2',
             'RoutingConfig': {'AdditionalVersionWeights': {'4': 0.1}}},
        ]
        self.aws.resources.append({
            'ResourceType': 'AWS::Lambda::Version',
            'PhysicalResourceId': f'arn:aws:lambda:eu-central-1:123456789012:function:{FUNCTION}:6',
        })
        self.assertEqual(self.run_prune(), ['1', '3', '5', '7'])

    def test_fewer_than_five_versions_needs_no_cleanup(self):
        self.aws.versions = [{'Version': str(n)} for n in [10, 11, 12]]
        self.assertEqual(self.run_prune(), [])
        self.assertEqual(self.aws.deletes, [])

    def test_dry_run_does_not_delete(self):
        self.assertEqual(len(self.run_prune(dry_run=True)), 7)
        self.assertEqual(self.aws.deletes, [])

    def test_failed_or_unfinished_deployments_cannot_cleanup(self):
        for status in ['UPDATE_IN_PROGRESS', 'UPDATE_ROLLBACK_COMPLETE', 'ROLLBACK_COMPLETE',
                       'UPDATE_COMPLETE_CLEANUP_IN_PROGRESS', 'UPDATE_FAILED']:
            with self.subTest(status=status):
                self.aws.status = status
                with self.assertRaises(ValueError):
                    self.run_prune()
        self.assertEqual(self.aws.deletes, [])

    def test_concurrent_stack_update_stops_cleanup(self):
        self.aws.change_status = True
        with self.assertRaises(ValueError):
            self.run_prune()
        self.assertEqual(self.aws.deletes, [])

    def test_mismatched_stack_or_missing_version_cannot_cleanup(self):
        for resources in [self.aws.resources[1:], self.aws.resources[:1]]:
            with self.subTest(resources=resources):
                self.aws.resources = resources
                with self.assertRaises(ValueError):
                    self.run_prune()
        self.assertEqual(self.aws.deletes, [])

    def test_missing_default_alias_cannot_cleanup(self):
        self.aws.aliases = []
        with self.assertRaises(ValueError):
            self.run_prune()
        self.assertEqual(self.aws.deletes, [])

    def test_inventory_failure_does_not_delete(self):
        for operation in ['describe-stacks', 'list-stack-resources', 'list-aliases', 'list-versions-by-function']:
            with self.subTest(operation=operation):
                self.aws.fail = operation
                with self.assertRaises(subprocess.CalledProcessError):
                    self.run_prune()
        self.assertEqual(self.aws.deletes, [])

    def test_invalid_retention_or_qualified_function_is_rejected_before_aws_calls(self):
        for keep in [0, -1]:
            with self.assertRaises(ValueError):
                self.run_prune(keep=keep)
        with self.assertRaises(ValueError):
            MODULE.prune(self.aws, FUNCTION + ':DEFAULT', STACK)
        self.assertEqual(self.aws.calls, [])

    def test_cli_keeps_pagination_and_passes_profile_region_and_numeric_qualifier(self):
        with patch.object(MODULE.subprocess, 'run') as run:
            run.return_value.stdout = '{"Versions": []}'
            aws = MODULE.AwsCli('eu-central-1', 'test-profile')
            self.assertEqual(aws('lambda', 'list-versions-by-function', '--function-name', FUNCTION),
                             {'Versions': []})
            self.assertEqual(run.call_args.args[0], [
                'aws', 'lambda', 'list-versions-by-function', '--function-name', FUNCTION,
                '--output', 'json', '--no-cli-pager', '--region', 'eu-central-1', '--profile', 'test-profile',
            ])
            run.return_value.stdout = ''
            self.assertEqual(aws('lambda', 'delete-function', '--function-name', FUNCTION,
                                 '--qualifier', '1'), {})
            self.assertIn('--qualifier', run.call_args.args[0])
            self.assertTrue(run.call_args.kwargs['check'])


class ApiDeploymentTests(unittest.TestCase):
    def test_function_overrides_are_qualified_once(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            aws = directory / 'aws'
            aws.write_text('#!/usr/bin/env python3\n'
                           'import json, os, sys\n'
                           'with open(os.environ["TEST_AWS_LOG"], "a") as log:\n'
                           '    log.write(json.dumps(sys.argv[1:]) + "\\n")\n')
            aws.chmod(0o755)
            tclsh = directory / 'tclsh'
            tclsh.write_text('#!/bin/sh\nprintf ZTEST\n')
            tclsh.chmod(0o755)
            logfile = directory / 'calls.jsonl'
            environment = dict(os.environ, PATH=f'{directory}:{os.environ["PATH"]}',
                               TCLSH=str(tclsh), TEST_AWS_LOG=str(logfile))
            for target in [None, 'custom', 'custom:DEFAULT', 'custom:OTHER', 'custom:12',
                           'arn:aws:lambda:eu-central-1:123456789012:function:custom',
                           'arn:aws:lambda:eu-central-1:123456789012:function:custom:DEFAULT']:
                with self.subTest(target=target):
                    environment.pop('LAMBDA_FUNCTION_NAME', None)
                    if target is not None:
                        environment['LAMBDA_FUNCTION_NAME'] = target
                    logfile.write_text('')
                    subprocess.run(['bash', str(ROOT / 'devops/infra/40-deploy-api-gateway.sh')],
                                   check=True, env=environment, capture_output=True, text=True)
                    calls = [json.loads(line) for line in logfile.read_text().splitlines()]
                    expected = {
                        None: 'prod-Api-TtrekWebsite-Function:DEFAULT',
                        'custom': 'custom:DEFAULT',
                        'arn:aws:lambda:eu-central-1:123456789012:function:custom':
                            'arn:aws:lambda:eu-central-1:123456789012:function:custom:DEFAULT',
                    }.get(target, target)
                    self.assertIn('LambdaFunctionName=' + expected, calls[0])


if __name__ == '__main__':
    unittest.main()
