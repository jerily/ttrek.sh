import importlib.util
import copy
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('gateway', ROOT / 'devops/generate-api-gateway.py')
gateway = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gateway)


class ApiGatewayRoutes(unittest.TestCase):
    def test_production_routes_and_names(self):
        manifest = json.loads((ROOT / 'etc/routes.json').read_text())['routes']
        template = json.loads((ROOT / 'devops/infra/40-api-gateway.json').read_text())
        expected = {f"{route['method']} {route['path'].rstrip('/') or '/'}"
                    for route in manifest if not route.get('cdn_on_prod', False)}
        actual = {}
        for name, resource in template['Resources'].items():
            if resource['Type'] != 'AWS::ApiGatewayV2::Route':
                continue
            key = resource['Properties']['RouteKey']
            path = key.split(' ', 1)[1]
            if path != '/':
                self.assertNotIn('', path[1:].split('/'), key)
            self.assertEqual(name, gateway.route_logical_id(key))
            self.assertNotRegex(name, r'^Route[0-9a-f]{16}$')
            self.assertEqual(resource['Properties']['AuthorizationType'], 'NONE')
            actual[key] = name
        self.assertEqual(set(actual), expected)
        self.assertEqual(len(actual.values()), len(set(actual.values())))
        self.assertFalse(any('{proxy+}' in key for key in actual))
        self.assertEqual(actual['GET /user/login'], 'GetUserLoginRoute')
        self.assertEqual(actual['POST /user/google/start'], 'PostUserGoogleStartRoute')
        self.assertEqual(actual['GET /user/google/callback'], 'GetUserGoogleCallbackRoute')
        self.assertEqual(actual['HEAD /user/google/callback'], 'HeadUserGoogleCallbackRoute')
        self.assertEqual(actual['POST /user/google/unlink'], 'PostUserGoogleUnlinkRoute')
        for route in ['/user/email-login', '/user/email-login/verify']:
            for method in ['GET', 'HEAD', 'POST']:
                self.assertIn(f'{method} {route}', actual)
        self.assertEqual(actual['POST /forum/topic/{id}'], 'PostForumTopicByIdRoute')
        self.assertNotIn('GET /css/{path+}', actual)
        self.assertNotIn('GET /forum/_assets/{asset}', actual)
        self.assertNotIn('GET /user/_assets/admin.css', actual)
        for path in ['/blog', '/docs', '/forum', '/request-monitor', '/user']:
            for method in ['GET', 'HEAD']:
                self.assertIn(f'{method} {path}', actual)
                self.assertNotIn(f'{method} {path}/', actual)
        self.assertEqual(actual['GET /'], 'RootRoute')
        self.assertEqual(actual['HEAD /'], 'HeadRootRoute')
        dependencies = template['Resources']['ApiStage']['DependsOn']
        self.assertEqual(set(dependencies), {'SitePermission', *actual.values()})

    def test_trailing_slash_aliases_collapse_without_changing_local_routes(self):
        routes = [
            {'method': 'GET', 'path': '/', 'function': 'site'},
            {'method': 'GET', 'path': '/docs', 'function': 'site'},
            {'method': 'GET', 'path': '/docs/', 'function': 'site'},
            {'method': 'HEAD', 'path': '/docs/', 'function': 'site'},
            {'method': 'GET', 'path': '/docs/{path+}', 'function': 'site'},
            {'method': 'GET', 'path': '/assets/{path+}', 'function': 'site', 'cdn_on_prod': True},
        ]
        before = copy.deepcopy(routes)
        expected = {('GET', '/'), ('GET', '/docs'), ('HEAD', '/docs'), ('GET', '/docs/{path+}')}
        for definitions in [routes, list(reversed(routes))]:
            result = gateway.production_routes(definitions)
            self.assertEqual({(route['method'], route['path']) for route in result}, expected)
            self.assertEqual(len(result), len(expected))
        self.assertEqual(routes, before)

    def test_conflicting_aliases_fail_instead_of_changing_the_backend(self):
        routes = [
            {'method': 'GET', 'path': '/docs', 'function': 'site'},
            {'method': 'GET', 'path': '/docs/', 'function': 'other'},
        ]
        for definitions in [routes, list(reversed(routes))]:
            with self.assertRaisesRegex(ValueError, 'Conflicting API Gateway routes'):
                gateway.production_routes(definitions)

    def test_invalid_paths_fail_before_generation(self):
        for path in ['', 'docs', '//', '//docs', '/docs//page', '/docs//', None]:
            with self.subTest(path=path), self.assertRaisesRegex(ValueError, 'Invalid API Gateway route path'):
                gateway.production_routes([{'method': 'GET', 'path': path, 'function': 'site'}])

    def test_cdn_flag_must_be_boolean(self):
        for value in [0, 1, 'true', None]:
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, 'cdn_on_prod must be a boolean'):
                gateway.production_routes([{'method': 'GET', 'path': '/assets', 'function': 'site', 'cdn_on_prod': value}])


if __name__ == '__main__':
    unittest.main()
