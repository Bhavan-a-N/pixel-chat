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
4. **Chat List**: The app auto-logs in and lands on `/home` showing your display name in the app bar and an empty state "No conversations yet".
5. **Session Persistence**: Kill the app from Android's app switcher (swipe away). Launch the app again from the launcher. Notice it initializes on `/splash`, verifies `/api/auth/me`, and opens directly to `/home` without flashing the login screen.
6. **Log Out**: Tap the "Log Out" button in the app bar. The secure storage is wiped, WebSocket disconnects, and the app redirects back to `/login`.
7. **Offline / Cold-Start Resilience**: Stop the Django server and open the app or send a message. The app displays the friendly "Waking up server, please wait..." or "Waiting to reconnect..." connection banner instead of crashing or logging you out!

### Message Status and Delivery Receipts (Ticks)
Messages display real-time status indicators (ticks) derived from monotonic sequence pointers:
- **Pending (Clock Icon)**: Message is queued locally in the client's outbox and awaiting socket acknowledgment.
- **Sent (Single Check `✓`)**: Message was committed on the server and acknowledged to the sender (`seq > otherDeliveredSeq`).
- **Delivered (Double Check `✓✓`)**: Message was delivered to the recipient's active client (`seq <= otherDeliveredSeq`).
- **Read (Double Check in Filled Badge `✓✓`)**: Recipient opened the chat screen and viewed the message (`seq <= otherReadSeq`). Distinctly styled with a filled badge for visual accessibility.
- **Failed**: Error text + Retry button to resend with the exact same client ID.

#### Manual Verification for Delivery & Read Receipts:
1. Launch two clients (e.g. two browser/emulator windows or emulator + phone) logged in as `alice` and `bob`.
2. Open the DM on `alice`'s client, but keep `bob`'s client on the conversation list screen (`/home`).
3. Send a message from `alice`:
   - Initially displays pending (clock), transitions to single tick (sent).
   - Once Bob's client receives the message in the background, Bob automatically sends `chat.delivered` (debounced ~300ms).
   - Alice's message bubble transitions to double ticks (delivered) without Bob opening the chat!
4. Bob taps the conversation to enter the chat screen:
   - Bob views the new message at the bottom of the screen.
   - Bob's client sends `chat.read` for the highest visible sequence number.
   - Alice's message bubble transitions in real-time to the double check with filled badge (read)!

---

### Group Chats

Groups allow multi-user conversations with administrative roles, system event audit trails, and unified message delivery receipts.

- **Group Creation**: Create a group with a name (1-50 chars) and initial members. Creator is automatically assigned the `admin` role.
- **Role Permissions**: Admins can rename groups, add members, remove members, and promote/demote members. Demoting the last admin is rejected.
- **Unified Delivery Receipts**: Tick indicators for group messages use the same model as DMs: an outgoing message shows delivered only when *all* other members have delivered pointers $\ge \text{seq}$, and read only when *all* other members have read pointers $\ge \text{seq}$. Long-press "Message Info" shows per-member breakdown.
- **System Messages**: Lifecycle events (group created, member added, member removed, member left, role changed, renamed) are recorded as system messages with structured `system_data` and displayed as centered chips.
- **History Visibility & Privacy**: New members start from their join point (`joined_at_seq`), ensuring messages sent prior to joining remain private.

#### Manual Verification for Group Chats:
1. Log in as `alice`, `bob`, and `charlie` across three clients/sessions.
2. `alice` taps "New Group" (or `+`), enters group name "Project Apollo", adds `bob`, and taps "Create".
3. `alice` and `bob` both see "Project Apollo" in their conversation lists with initial system message: "alice created the group 'Project Apollo'".
4. `alice` sends messages. `bob` views them; ticks advance to double check (read).
5. `alice` opens Group Details (tap group title in chat header), taps "Add Member", searches `charlie`, and adds them.
6. `charlie` sees the group appear in their chat list, with history starting strictly from the "alice added charlie" system message (previous messages are hidden).
7. `alice` taps "Make admin" next to `bob`. A system message announces "alice promoted bob to an admin".
8. `bob` removes `charlie`. `charlie`'s chat immediately indicates they have been removed, queued messages in outbox are discarded, and no further group events are received.
9. When `alice` and `bob` leave the group, the conversation and messages are automatically cleaned up.

---

## Deploy and install (production)

Backend deployment (Render + Neon + Render Key Value, Singapore regions) is documented step-by-step in [docs/DEPLOY.md](docs/DEPLOY.md). Android release signing and APK build: [docs/ANDROID_SIGNING.md](docs/ANDROID_SIGNING.md).

### Install the release APK on a friend's phone

1. Copy `app-release.apk` to the phone (USB, cloud link, etc.).
2. On the phone, open the APK. Android may block installs from unknown sources.
3. **Android 8+:** allow **Install unknown apps** for the app you use to open the file (Chrome, Files, etc.).
4. **Older versions:** enable **Unknown sources** in security settings.
5. Complete install and open **pixel_chat**.
6. Sign up with the shared **invite code** (you distribute this privately — it is set as `INVITE_CODE` on Render).

### Free host idle sleep

The Render **free web** tier spins down after about **15 minutes** without inbound HTTP or WebSocket **messages**. The first request after sleep can take **~1 minute**. The app shows **“Connecting…” / server waking** and retries automatically — expect a slower first message after idle, not a broken install.

Neon may also **suspend** the database after a few minutes of no queries; the first API call after that can add a short delay. Do not use `/health/ready` for frequent keep-warm pings (see ADR 0027).



### Database Backups (Neon PostgreSQL)

A backup script is provided at scripts/backup-db.ps1.
It uses pg_dump to export the Neon database to .sql files.

**How to Schedule Daily Backups:**
1. Install PostgreSQL client tools (so pg_dump is on your PATH).
2. Set DATABASE_URL as a User or System environment variable matching your Neon production connection string.
3. The task is configured in Windows Task Scheduler under the name **PixelChatBackup** to run daily at 3:00 AM, executing the script.
4. Backups are saved locally to D:\pixel-chat\backups\ by default (override with PIXEL_CHAT_BACKUP_DIR env var).
