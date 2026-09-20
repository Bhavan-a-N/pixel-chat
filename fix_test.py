import re
with open(r'backend\apps\accounts\tests\test_auth.py', 'r') as f:
    content = f.read()
new_test = '''@pytest.mark.django_db
class TestThrottling:
    @patch('rest_framework.throttling.ScopedRateThrottle.get_rate')
    def test_throttle_triggers(self, mock_get_rate, api_client):
        mock_get_rate.return_value = '2/min'
        from apps.accounts.views import LoginView
        from rest_framework.throttling import ScopedRateThrottle
        original_classes = LoginView.throttle_classes
        LoginView.throttle_classes = [ScopedRateThrottle]
        try:
            url = reverse('login')
            api_client.post(url, {"email": "u1@example.com", "password": "pw"})
            api_client.post(url, {"email": "u1@example.com", "password": "pw"})
            res = api_client.post(url, {"email": "u1@example.com", "password": "pw"})
            assert res.status_code == status.HTTP_429_TOO_MANY_REQUESTS
        finally:
            LoginView.throttle_classes = original_classes
'''
content = re.sub(r'@pytest\.mark\.django_db\nclass TestThrottling:.*', new_test, content, flags=re.DOTALL)
with open(r'backend\apps\accounts\tests\test_auth.py', 'w') as f:
    f.write(content)
