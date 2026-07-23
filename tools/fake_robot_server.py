"""
가짜 로봇 서버 — LIMO인 척 장애물 감지 JSON을 앱으로 쏘는 테스트 서버
실행: pip3 install websockets && python3 fake_robot_server.py
앱은 ws://<이 컴퓨터 IP>:8765 로 접속 (시뮬레이터면 ws://localhost:8765)

시나리오: 안전 → 사람 접근(3.0→0.4m) → 안전 → 의자 → 계단 긴급 → 반복
"""

import asyncio
import json

import websockets

SCENARIO = [
    # (type, direction, distance, urgency, 유지시간초)
    ("none",   "front", 9.9, "safe",      3),
    ("person", "front", 3.0, "info",      2),
    ("person", "front", 2.2, "warn",      2),
    ("person", "front", 1.4, "warn",      2),
    ("person", "front", 0.4, "emergency", 3),
    ("none",   "front", 9.9, "safe",      3),
    ("chair",  "right", 1.8, "warn",      3),
    ("box",    "left",  1.1, "warn",      3),
    ("stairs", "front", 0.5, "emergency", 3),
    ("none",   "front", 9.9, "safe",      4),
]


async def handler(ws):
    print(f"앱 연결됨: {ws.remote_address}")
    try:
        while True:
            for typ, direction, dist, urgency, hold in SCENARIO:
                msg = json.dumps({
                    "type": typ, "direction": direction,
                    "distance": dist, "urgency": urgency,
                })
                await ws.send(msg)
                print("전송:", msg)
                await asyncio.sleep(hold)
    except websockets.ConnectionClosed:
        print("앱 연결 종료")


async def main():
    async with websockets.serve(handler, "0.0.0.0", 8765):
        print("가짜 로봇 서버 시작: ws://0.0.0.0:8765 (종료: Ctrl+C)")
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())