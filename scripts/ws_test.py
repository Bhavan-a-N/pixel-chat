"""
Interactive test script for Pixel Chat WebSocket endpoint.
Usage:
    python scripts/ws_test.py --token <JWT_ACCESS_TOKEN> --conv <CONVERSATION_ID>
"""

import argparse
import asyncio
import json
import sys
import uuid
import websockets


async def run_ws_test(ws_url: str, token: str, conversation_id: str):
    headers = {
        "Authorization": f"Bearer {token}",
    }

    print(f"Connecting to {ws_url} with provided Bearer token...")
    try:
        async with websockets.connect(ws_url, additional_headers=headers) as ws:
            print("[+] WebSocket connection established successfully!")

            client_id = str(uuid.uuid4())
            send_payload = {
                "v": 1,
                "type": "chat.send",
                "client_id": client_id,
                "payload": {
                    "conversation_id": conversation_id,
                    "body": "Hello from ws_test.py script!",
                },
            }

            print(f"\n[>] Sending message (client_id={client_id}):")
            print(json.dumps(send_payload, indent=2))
            await ws.send(json.dumps(send_payload))

            # Receive ack
            ack_raw = await asyncio.wait_for(ws.recv(), timeout=5.0)
            ack = json.loads(ack_raw)
            print(f"\n[<] Received ACK from server:")
            print(json.dumps(ack, indent=2))

            # Receive broadcast (if listening to own user group)
            try:
                msg_raw = await asyncio.wait_for(ws.recv(), timeout=3.0)
                msg = json.loads(msg_raw)
                print(f"\n[<] Received broadcast:")
                print(json.dumps(msg, indent=2))
            except asyncio.TimeoutError:
                print("\n[*] No immediate broadcast on same socket (broadcast routed to user group).")

            # Resend with exact same client_id to test idempotency
            print(f"\n[>] Testing idempotency (resending same client_id={client_id})...")
            await ws.send(json.dumps(send_payload))

            dup_ack_raw = await asyncio.wait_for(ws.recv(), timeout=5.0)
            dup_ack = json.loads(dup_ack_raw)
            print(f"[<] Received duplicate ACK (status should be sent, no new seq):")
            print(json.dumps(dup_ack, indent=2))
            assert dup_ack.get("payload", {}).get("status") == "sent", (
                "Duplicate send should return status: sent"
            )

            print("\n[+] Verification completed successfully!")

    except websockets.exceptions.InvalidStatusCode as e:
        print(f"[-] Connection rejected by server with HTTP status code: {e.status_code}")
    except websockets.exceptions.ConnectionClosed as e:
        print(f"[-] Connection closed by server with code: {e.code} ({e.reason})")
    except Exception as e:
        print(f"[-] Unexpected error: {e}")


def main():
    parser = argparse.ArgumentParser(description="Test Pixel Chat WebSocket")
    parser.add_argument("--url", default="ws://127.0.0.1:8000/ws/chat/", help="WebSocket URL")
    parser.add_argument("--token", required=True, help="JWT access token")
    parser.add_argument("--conv", required=True, help="Conversation UUID")
    args = parser.parse_args()

    asyncio.run(run_ws_test(args.url, args.token, args.conv))


if __name__ == "__main__":
    main()
