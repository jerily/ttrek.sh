import importlib.util
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
        expected = {f"{route['method']} {route['path']}" for route in manifest if not route.get('cdn_on_prod', False)}
        actual = {}
        for name, resource in template['Resources'].items():
            if resource['Type'] != 'AWS::ApiGatewayV2::Route':
                continue
            key = resource['Properties']['RouteKey']
            self.assertEqual(name, gateway.route_logical_id(key))
            self.assertNotRegex(name, r'^Route[0-9a-f]{16}$')
            self.assertEqual(resource['Properties']['AuthorizationType'], 'NONE')
            actual[key] = name
        self.assertEqual(set(actual), expected)
        self.assertEqual(len(actual.values()), len(set(actual.values())))
        self.assertFalse(any('{proxy+}' in key for key in actual))
        self.assertEqual(actual['GET /user/login'], 'GetUserLoginRoute')
        self.assertEqual(actual['POST /forum/topic/{id}'], 'PostForumTopicByIdRoute')
        self.assertNotIn('GET /css/{path+}', actual)
        self.assertNotIn('GET /forum/_assets/{asset}', actual)
        self.assertNotIn('GET /user/_assets/admin.css', actual)


if __name__ == '__main__':
    unittest.main()
