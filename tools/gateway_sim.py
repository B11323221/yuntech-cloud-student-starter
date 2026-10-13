import os
import json
import time
import random
import paho.mqtt.client as mqtt
from paho.mqtt.enums import CallbackAPIVersion

IOT_ENDPOINT = os.getenv("IOT_ENDPOINT")
IOT_TOPIC = os.getenv("IOT_TOPIC")
IOT_CLIENT_ID = os.getenv("IOT_CLIENT_ID")
IOT_CA = os.getenv("IOT_CA")
IOT_CERT = os.getenv("IOT_CERT")
IOT_KEY = os.getenv("IOT_KEY")
DEVICE_IDS = os.getenv("IOT_DEVICE_IDS", "").split(",")

def main():
    client = mqtt.Client(
        client_id=IOT_CLIENT_ID,
        callback_api_version=CallbackAPIVersion.VERSION2
    )
    client.tls_set(
        ca_certs=IOT_CA,
        certfile=IOT_CERT,
        keyfile=IOT_KEY
    )
    
    print(f"Connecting to IoT Core {IOT_ENDPOINT}...")
    client.connect(IOT_ENDPOINT, 8883, 60)
    client.loop_start()
    
    try:
        for i in range(10):
            device_id = DEVICE_IDS[i % len(DEVICE_IDS)]
            payload = {
                "event_id": f"evt-{int(time.time() * 1000)}-{i}",
                "device_id": device_id,
                "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "data": {"value": random.randint(20, 100)}
            }
            client.publish(IOT_TOPIC, json.dumps(payload), qos=1)
            print(f"Published event for device {device_id}")
            time.sleep(0.5)
    finally:
        client.loop_stop()
        client.disconnect()

if __name__ == "__main__":
    main()
