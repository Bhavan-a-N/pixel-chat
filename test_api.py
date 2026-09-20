import requests

base = 'http://localhost:8000'

print('1. Register (Correct Invite)')
r1 = requests.post(f'{base}/api/auth/register', json={
    'email': 'test1@example.com', 'username': 'bob', 'password': 'StrongPassword123!',
    'display_name': 'Bob Test', 'invite_code': 'pixelchat2026'
})
print('Status:', r1.status_code)
print(r1.text)

print('\n2. Register (Wrong Invite)')
r2 = requests.post(f'{base}/api/auth/register', json={
    'email': 'test3@example.com', 'username': 'bobby', 'password': 'StrongPassword123!',
    'display_name': 'Bobby Test', 'invite_code': 'wrong'
})
print('Status:', r2.status_code)
print(r2.text)

print('\n3. Register (Bob after bob)')
r3 = requests.post(f'{base}/api/auth/register', json={
    'email': 'test2@example.com', 'username': 'Bob', 'password': 'StrongPassword123!',
    'display_name': 'Bob 2 Test', 'invite_code': 'pixelchat2026'
})
print('Status:', r3.status_code)
print(r3.text)

print('\n4. Login as bob')
r4 = requests.post(f'{base}/api/auth/login', json={
    'email': 'test1@example.com', 'password': 'StrongPassword123!'
})
print('Status:', r4.status_code)
tokens = r4.json()
access = tokens.get('access')
refresh1 = tokens.get('refresh')

print('\n5. Call /api/auth/me')
r5 = requests.get(f'{base}/api/auth/me', headers={'Authorization': f'Bearer {access}'})
print('Status:', r5.status_code)
print(r5.text)

print('\n6. Refresh Token')
r6 = requests.post(f'{base}/api/auth/refresh', json={'refresh': refresh1})
print('Status:', r6.status_code)
refresh2 = r6.json().get('refresh')

print('\n7. Reuse Old Refresh Token')
r7 = requests.post(f'{base}/api/auth/refresh', json={'refresh': refresh1})
print('Status:', r7.status_code)
print(r7.text)

print('\n8. Hit /health')
r8 = requests.get(f'{base}/health')
print('Status:', r8.status_code)
print(r8.text)
