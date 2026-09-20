# Pixel Chat

## Backend Quickstart

1. **Start the database:**
   ```powershell
   docker compose up -d db
   ```

2. **Setup virtual environment and install dependencies:**
   ```powershell
   python -m venv backend\.venv
   .\backend\.venv\Scripts\Activate.ps1
   pip install -r backend\requirements.txt
   ```

3. **Environment Variables:**
   Copy `backend\.env.example` to `backend\.env` and customize as needed. Ensure `SECRET_KEY` and `INVITE_CODE` are set.

4. **Run migrations:**
   ```powershell
   python backend\manage.py migrate
   ```

5. **Start the server:**
   ```powershell
   python backend\manage.py runserver
   ```

6. **Cleanup expired tokens (Cron job):**
   Use SimpleJWT's built-in command to clear out expired blacklisted tokens.
   ```powershell
   python backend\manage.py flushexpiredtokens
   ```

---

## API Endpoints (PowerShell Curl Examples)

### Register a new user
```powershell
Invoke-RestMethod -Uri "http://localhost:8000/api/auth/register" -Method Post -Body (@{
    email="test@example.com"
    username="testuser"
    password="StrongPassword123!"
    display_name="Test User"
    invite_code="pixelchat2026"
} | ConvertTo-Json) -ContentType "application/json"
```

### Login
```powershell
$login = Invoke-RestMethod -Uri "http://localhost:8000/api/auth/login" -Method Post -Body (@{
    email="test@example.com"
    password="StrongPassword123!"
} | ConvertTo-Json) -ContentType "application/json"
$access = $login.access
$refresh = $login.refresh
```

### Refresh Token
```powershell
$refreshRes = Invoke-RestMethod -Uri "http://localhost:8000/api/auth/refresh" -Method Post -Body (@{
    refresh=$refresh
} | ConvertTo-Json) -ContentType "application/json"
$access = $refreshRes.access
```

### Logout (Blacklist Refresh Token)
```powershell
Invoke-RestMethod -Uri "http://localhost:8000/api/auth/logout" -Method Post -Headers @{Authorization="Bearer $access"} -Body (@{
    refresh=$refresh
} | ConvertTo-Json) -ContentType "application/json"
```

### Get Profile
```powershell
Invoke-RestMethod -Uri "http://localhost:8000/api/auth/me" -Method Get -Headers @{Authorization="Bearer $access"}
```

### Update Display Name
```powershell
Invoke-RestMethod -Uri "http://localhost:8000/api/auth/me" -Method Patch -Headers @{Authorization="Bearer $access"} -Body (@{
    display_name="New Name"
} | ConvertTo-Json) -ContentType "application/json"
```

### Search Users
```powershell
Invoke-RestMethod -Uri "http://localhost:8000/api/users/search?username=test" -Method Get -Headers @{Authorization="Bearer $access"}
```

### Health Check
```powershell
Invoke-RestMethod -Uri "http://localhost:8000/health" -Method Get
```

---

## How to verify manually
1. Launch the server (`runserver`).
2. Run the **Register** command above. You should get a 201 Created.
3. Run the **Login** command to grab your access and refresh tokens.
4. Try fetching your profile using the **Get Profile** command.
5. Try the **Health Check** to ensure the DB is connected!
