# Pixel Chat

## Backend Quickstart

1. **Start the database and cache:**
   ```powershell
   docker compose up -d
   ```

2. **Setup virtual environment and install dependencies:**
   ```powershell
   python -m venv backend\.venv
   .\backend\.venv\Scripts\Activate.ps1
   pip install -r backend\requirements.txt
   ```

3. **Environment Variables:**
   Copy `backend\.env.example` to `backend\.env` and customize as needed. Ensure `SECRET_KEY`, `INVITE_CODE`, and `REDIS_URL` are set.

4. **Run migrations:**
   ```powershell
   python backend\manage.py migrate
   ```

5. **Start the server (ASGI/Daphne):**
   ```powershell
   python backend\manage.py runserver 0.0.0.0:8000
   ```

6. **Cleanup expired tokens (Cron job):**
   Use SimpleJWT's built-in command to clear out expired blacklisted tokens.
   ```powershell
   python backend\manage.py flushexpiredtokens
   ```

---

## Chat Backend (WebSocket & REST)

### 1. Create or Find a Direct Message (REST)
```powershell
Invoke-RestMethod -Uri "http://localhost:8000/api/conversations/dm" -Method Post -Headers @{Authorization="Bearer $access"} -Body (@{
    username="bob"
} | ConvertTo-Json) -ContentType "application/json"
```

### 2. List Active Conversations (REST)
```powershell
Invoke-RestMethod -Uri "http://localhost:8000/api/conversations" -Method Get -Headers @{Authorization="Bearer $access"}
```

### 3. Fetch Message History (Pagination)
```powershell
# History (newest first, before seq)
Invoke-RestMethod -Uri "http://localhost:8000/api/conversations/<CONVERSATION_ID>/messages?before_seq=50&limit=30" -Method Get -Headers @{Authorization="Bearer $access"}

# Catch-up (oldest first, after seq)
Invoke-RestMethod -Uri "http://localhost:8000/api/conversations/<CONVERSATION_ID>/messages?after_seq=20&limit=30" -Method Get -Headers @{Authorization="Bearer $access"}
```

### 4. Interactive WebSocket Verification (`scripts/ws_test.py`)
A standalone test script using `websockets` is included in `scripts/ws_test.py`:
```powershell
python scripts\ws_test.py --token <JWT_ACCESS_TOKEN> --conv <CONVERSATION_ID>
```
The script performs:
- Authenticated handshake via HTTP `Authorization: Bearer <token>`.
- Sends a `chat.send` event with a unique `client_id`.
- Awaits `chat.ack` from the server (verifying monotonic sequence assignment).
- Resends with the identical `client_id` to verify idempotency (verifying no duplicate seq is assigned).

---

## Flutter Quickstart

1. **Prerequisites:**
   Ensure Flutter 3.38.1 is installed and available in your PowerShell environment (`flutter --version`).

2. **Install dependencies:**
   ```powershell
   cd app
   flutter pub get
   ```

3. **Run Code Analysis and Tests:**
   ```powershell
   cd app
   flutter analyze
   flutter test
   ```

4. **Run on Android Emulator:**
   The Android Emulator automatically routes `10.0.2.2` to the host machine's loopback interface.
   Ensure the backend is running, then launch the app:
   ```powershell
   cd app
   flutter run
   ```
   *(Default `API_BASE_URL` is configured to `http://10.0.2.2:8000`).*

5. **Connecting a Physical Phone (LAN Setup):**
   To test on a physical Android device connected to the same local Wi-Fi:
   - Find your PC's local IP address by running:
     ```powershell
     ipconfig
     ```
     Locate the `IPv4 Address` under your active Wi-Fi / Ethernet adapter (e.g. `192.168.1.150`).
   - Ensure the Django server is listening on all interfaces:
     ```powershell
     python backend\manage.py runserver 0.0.0.0:8000
     ```
     *(Make sure Windows Defender Firewall allows incoming connections on port 8000).*
   - Run the Flutter app targeting your PC's LAN IP:
     ```powershell
     cd app
     flutter run --dart-define=API_BASE_URL=http://<YOUR_PC_LAN_IP>:8000
     ```

---

## How to Verify Manually

### Backend Verification
1. Launch Postgres & Redis (`docker compose up -d`).
2. Run migrations: `python backend\manage.py migrate`.
3. Start the server: `python backend\manage.py runserver 0.0.0.0:8000`.
4. Register two users (`alice`, `bob`) and log in to obtain access tokens.
5. Create a DM between `alice` and `bob` via `POST /api/conversations/dm`.
6. Run `python scripts\ws_test.py --token <ALICE_ACCESS_TOKEN> --conv <CONV_ID>` in one terminal.
7. Open a second terminal and connect as `bob` to observe real-time broadcasts.

### Flutter App Manual Verification Flow (Android Emulator)
1. Start the backend: `python backend\manage.py runserver 0.0.0.0:8000`.
2. Launch an Android emulator, then run `flutter run` inside `app\`.
3. **Sign Up**: Tap "Sign Up", fill in valid details (min 3 char username, 8+ char password, correct invite code `pixelchat2026`). Tap "Sign Up".
4. **Home Screen**: The app auto-logs in and lands on `/home` showing your display name, `@username`, and avatar seed.
5. **Session Persistence**: Kill the app from Android's app switcher (swipe away). Launch the app again from the launcher. Notice it initializes on `/splash`, verifies `/api/auth/me`, and opens directly to `/home` without flashing the login screen.
6. **Log Out**: Tap the "Log Out" button. The secure storage is wiped, backend refresh token is blacklisted, and the app redirects back to `/login`.
7. **Offline / Cold-Start Resilience**: Stop the Django server (or turn on Airplane mode in the emulator) and reopen the app. Notice the app displays a friendly "Connection Issue" screen with a "Retry Connection" button instead of crashing or logging you out!
